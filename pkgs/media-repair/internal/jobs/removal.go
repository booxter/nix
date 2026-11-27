package jobs

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/planning"
	"gorm.io/gorm"
)

type InspectedCase struct {
	Fingerprint string
	Evidence    json.RawMessage
}

// Carry the changed case back to the store so the operator can review it
// immediately. Legacy requests have no approval to compare.
type RemovalNeedsConfirmation struct {
	Current *InspectedCase
}

func (notice *RemovalNeedsConfirmation) Error() string {
	if notice.Current == nil {
		return "this removal has no saved approval; review the item and confirm removal again"
	}
	return "the source changed after removal was approved; review the item and confirm removal again"
}

func (store *Store) RequestRemoval(ctx context.Context, expected Job, at time.Time) error {
	return store.requestAction(ctx, expected, Delete, planning.Answer{}, &expected.SourceFingerprint, at)
}

// Automatic cleanup is authorized by the completed library item.
func (store *Store) RequestCleanup(ctx context.Context, expected Job, at time.Time) error {
	return store.requestAction(ctx, expected, Delete, planning.Answer{}, new(""), at)
}

func (store *Store) FinishRemoval(ctx context.Context, requested Job, failure error, at time.Time) error {
	return store.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var job Job
		if err := tx.First(&job, requested.ID).Error; err != nil {
			return err
		}
		if job.Revision != requested.Revision || job.PendingAction != Delete {
			return ErrConflict
		}

		job.UpdatedAt = at
		job.Outcome = OutcomeOther
		var notice *RemovalNeedsConfirmation
		switch {
		case failure == nil:
			job.State = Removed
			job.InQueue = false
			job.PendingAction = ""
			job.RemovalFingerprint = nil
			job.Reason = "queue removal completed"
		case errors.As(failure, &notice):
			if notice.Current != nil {
				if err := store.replaceRemovalCase(&job, *notice.Current, at); err != nil {
					return err
				}
			}
			job.Revision++
			job.PendingAction = ConfirmRemoval
			job.RemovalFingerprint = nil
			job.State = Blocked
			job.RetryAt = time.Time{}
			job.Reason = notice.Error()
		default:
			job.State = Blocked
			job.Reason = failure.Error()
			job.RetryAt = at.Add(5 * time.Minute)
		}

		return tx.Save(&job).Error
	})
}

// The inbox must show the evidence found by the removal worker. The old
// plan and any file or edition picked from it belong to the previous case.
func (store *Store) replaceRemovalCase(job *Job, current InspectedCase, at time.Time) error {
	job.SourceFingerprint = current.Fingerprint
	job.Evidence = current.Evidence
	inputs, err := store.planningInputs(*job)
	if err != nil {
		return err
	}
	job.PlanningFingerprint = inputs.Fingerprint()
	job.StableSince = at
	job.PlanningAttempts = 0
	job.CollectionError, job.CollectionOutcome = "", ""
	job.Findings = nil
	job.Plan, job.PlanResult = nil, nil
	job.SelectedFileID, job.SelectedReleaseID = "", 0
	return nil
}

func (store *Store) StartRemoval(ctx context.Context, id int64, at time.Time) (Job, error) {
	var job Job
	err := store.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.First(&job, id).Error; err != nil {
			return err
		}
		if job.PendingAction != Delete || job.State == Running || job.State == Importing {
			return ErrConflict
		}

		job.State = Removing
		job.RetryAt = time.Time{}
		job.UpdatedAt = at
		return tx.Save(&job).Error
	})

	return job, err
}

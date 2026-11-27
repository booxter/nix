package jobs

import (
	"context"
	"slices"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/planning"
	"gorm.io/gorm"
)

const (
	Reconsider     = "reconsider"
	Delete         = "delete"
	ConfirmRemoval = "confirm_removal"
)

func (job Job) AcceptsActions() bool {
	return job.InQueue && !active(job.State) && job.State != Removed
}

func (store *Store) RequestReconsideration(ctx context.Context, expected Job, answer planning.Answer, at time.Time) error {
	return store.requestAction(ctx, expected, Reconsider, answer, nil, at)
}

// Observation and repair continue while a request is being handled. Check
// the case again in the transaction that queues the action.
func (store *Store) requestAction(ctx context.Context, expected Job, action string, answer planning.Answer, removalFingerprint *string, at time.Time) error {
	return store.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var job Job
		if err := tx.First(&job, expected.ID).Error; err != nil {
			return err
		}
		if job.Revision != expected.Revision || job.SourceFingerprint != expected.SourceFingerprint ||
			job.State != expected.State || job.PendingAction != expected.PendingAction ||
			job.CollectionError != expected.CollectionError || !slices.Equal(job.Findings, expected.Findings) {
			return ErrConflict
		}
		if !job.AcceptsActions() {
			return ErrConflict
		}
		if action == Reconsider && job.State == Imported {
			return ErrConflict
		}

		job.Revision++
		job.PendingAction = action
		job.RemovalFingerprint = removalFingerprint
		job.Reason = ""
		job.Outcome = ""
		job.RetryAt = time.Time{}
		job.UpdatedAt = at
		if action == Reconsider {
			job.Answer = answer
			job.PlanResult = nil
			job.PlanningAttempts = 0
			job.State = Observed
		}

		return tx.Save(&job).Error
	})
}

// A new operator instruction invalidates an in-flight model answer even if the
// media files did not change. Revision tracks that local edit, not an API version.
func (store *Store) FinishPlanning(ctx context.Context, planned Job) error {
	return store.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var job Job
		if err := tx.First(&job, planned.ID).Error; err != nil {
			return err
		}
		if job.Revision != planned.Revision || job.SourceFingerprint != planned.SourceFingerprint ||
			active(job.State) || job.State == Removed || job.State == Imported {
			return ErrConflict
		}

		job.Plan = planned.Plan
		job.PlanResult = planned.PlanResult
		job.State = planned.State
		job.Reason = planned.Reason
		job.Outcome = planned.Outcome
		job.RetryAt = planned.RetryAt
		job.PlanningAttempts = planned.PlanningAttempts
		job.UpdatedAt = planned.UpdatedAt
		if planned.State == Ready || planned.State == Blocked {
			job.PendingAction = ""
		}
		if err := rememberPlanning(tx, job); err != nil {
			return err
		}

		return tx.Save(&job).Error
	})
}

func (store *Store) ReconcileQueue(ctx context.Context, service Service, present []QueueKey, at time.Time) error {
	return store.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var jobs []Job
		if err := tx.Where(&Job{Service: service}).Find(&jobs).Error; err != nil {
			return err
		}
		previous := QueueKeys(jobs)

		for index, job := range jobs {
			matched, owned, err := matchSavedJob(index, previous, present)
			if err != nil {
				return err
			}
			if matched >= 0 {
				if !owned {
					continue
				}
				if job.QueueID == present[matched].QueueID && job.InQueue && job.State != Removed {
					continue
				}
				job.QueueID = present[matched].QueueID
				job.InQueue = true
				if job.State == Removed {
					job.State = Blocked
					job.Reason = "queue entry is present again"
					job.Outcome = ""
				}
				if err := tx.Save(&job).Error; err != nil {
					return err
				}
				continue
			}
			if !job.InQueue {
				continue
			}

			job.InQueue = false
			job.UpdatedAt = at
			// The removal worker confirms an absent row even if the previous
			// DELETE failed or its response was lost.
			if !active(job.State) && job.State != Imported && job.PendingAction != Delete {
				// Queue presence is independent of a completed repair outcome.
				// Keep failures actionable if the same download returns later.
				if job.State != Blocked && job.State != Failed {
					job.State = Removed
					job.Reason = "no longer in the queue"
					job.Outcome = OutcomeOther
				}
				job.PendingAction = ""
				job.RemovalFingerprint = nil
			}
			if err := tx.Save(&job).Error; err != nil {
				return err
			}
		}

		return nil
	})
}

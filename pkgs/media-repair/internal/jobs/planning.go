package jobs

import (
	"context"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/planning"
	"gorm.io/gorm"
)

const (
	Reconsider = "reconsider"
	Delete     = "delete"
)

func (store *Store) RequestAction(ctx context.Context, id int64, action, guidance string, runtimeToleranceMS int64, at time.Time) error {
	answer := planning.Answer{Guidance: guidance, RuntimeToleranceMS: runtimeToleranceMS}
	return store.requestAction(ctx, id, action, answer, at, nil)
}

// Answers from the inbox apply only to the evidence and revision the user saw.
func (store *Store) RequestReconsideration(ctx context.Context, expected Job, answer planning.Answer, at time.Time) error {
	return store.requestAction(ctx, expected.ID, Reconsider, answer, at, &expected)
}

func (store *Store) requestAction(ctx context.Context, id int64, action string, answer planning.Answer, at time.Time, expected *Job) error {
	return store.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var job Job
		if err := tx.First(&job, id).Error; err != nil {
			return err
		}
		if expected != nil && (job.Revision != expected.Revision || job.SourceFingerprint != expected.SourceFingerprint ||
			job.State != expected.State || !job.InQueue || job.PendingAction != "" || job.CollectionError != "") {
			return ErrConflict
		}
		if active(job.State) || job.State == Removed || action != Reconsider && action != Delete {
			return ErrConflict
		}
		if action == Reconsider && job.State == Imported {
			return ErrConflict
		}

		job.Revision++
		job.PendingAction = action
		job.Reason = ""
		job.Outcome = ""
		job.RetryAt = time.Time{}
		job.UpdatedAt = at
		if action == Reconsider {
			job.Answer = answer
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
		if failure == nil {
			job.State = Removed
			job.InQueue = false
			job.PendingAction = ""
			job.Reason = "queue removal completed"
		} else {
			job.State = Blocked
			job.Reason = failure.Error()
			job.RetryAt = at.Add(5 * time.Minute)
		}

		return tx.Save(&job).Error
	})
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
		job.UpdatedAt = at
		return tx.Save(&job).Error
	})

	return job, err
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
			if !active(job.State) && job.State != Imported {
				// Queue presence is independent of a completed repair outcome.
				// Keep failures actionable if the same download returns later.
				if job.State != Blocked && job.State != Failed {
					job.State = Removed
					job.Reason = "no longer in the queue"
					job.Outcome = OutcomeOther
				}
				job.PendingAction = ""
			}
			if err := tx.Save(&job).Error; err != nil {
				return err
			}
		}

		return nil
	})
}

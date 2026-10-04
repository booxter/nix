package jobs

import (
	"context"
	"time"

	"gorm.io/gorm"
)

const (
	Reconsider = "reconsider"
	Delete     = "delete"
)

func (store *Store) RequestAction(ctx context.Context, id int64, action, guidance string, runtimeToleranceMS int64, at time.Time) error {
	return store.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var job Job
		if err := tx.First(&job, id).Error; err != nil {
			return err
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
		job.RetryAt = time.Time{}
		job.UpdatedAt = at
		if action == Reconsider {
			job.Guidance = guidance
			job.RuntimeToleranceMS = runtimeToleranceMS
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
		job.RetryAt = planned.RetryAt
		job.PlanningAttempts = planned.PlanningAttempts
		job.UpdatedAt = planned.UpdatedAt
		if planned.State == Ready || planned.State == Blocked {
			job.PendingAction = ""
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
		if failure == nil {
			job.State = Removed
			job.InQueue = false
			job.PendingAction = ""
			job.Reason = "queue tracking removed; media retained"
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
		previous := make([]QueueKey, len(jobs))
		for index, job := range jobs {
			previous[index] = job.QueueKey()
		}

		for index, job := range jobs {
			matched, err := MatchQueue(job.QueueKey(), present)
			if err != nil {
				return err
			}
			if matched >= 0 {
				// Matching in both directions prevents merging two album jobs.
				owner, err := MatchQueue(present[matched], previous)
				if err != nil {
					return err
				}
				if owner != index {
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
				job.State = Removed
				job.Reason = "no longer in the queue"
				job.PendingAction = ""
			}
			if err := tx.Save(&job).Error; err != nil {
				return err
			}
		}

		return nil
	})
}

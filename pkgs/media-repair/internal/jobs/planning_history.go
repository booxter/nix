package jobs

import (
	"encoding/json"
	"errors"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// Planning results outlive changes to the current case. Returning to an old
// input must not buy another decision. An operator instruction starts a new
// revision and explicitly permits reconsideration.
type PlanningResult struct {
	JobID       int64  `gorm:"primaryKey;autoIncrement:false"`
	Fingerprint string `gorm:"primaryKey"`
	Revision    int64  `gorm:"primaryKey;autoIncrement:false"`
	Complete    bool
	Attempts    int
	RetryAt     time.Time
	Reason      string
	Plan        json.RawMessage `gorm:"serializer:json"`
}

func rememberPlanning(tx *gorm.DB, job Job) error {
	if job.PlanningFingerprint == "" {
		return nil
	}
	result := PlanningResult{
		JobID: job.ID, Fingerprint: job.PlanningFingerprint, Revision: job.Revision,
		Complete: job.State != Observed, Attempts: job.PlanningAttempts,
		RetryAt: job.RetryAt, Reason: job.Reason, Plan: job.Plan,
	}
	return tx.Clauses(clause.OnConflict{UpdateAll: true}).Create(&result).Error
}

func observePlanning(tx *gorm.DB, job *Job, observed Job) (bool, error) {
	if observed.PlanningFingerprint == "" {
		return job.SourceFingerprint != observed.SourceFingerprint, nil
	}
	if job.PlanningFingerprint == "" {
		// Bootstrap from stored evidence, not the latest assessment. Existing
		// blocked jobs retain their decision when the new identity is introduced.
		job.PlanningFingerprint = observed.PreviousPlanningFingerprint
		if job.PlanningFingerprint == "" {
			job.PlanningFingerprint = observed.PlanningFingerprint
		}
		if job.State != Observed || job.PlanningAttempts > 0 {
			if err := rememberPlanning(tx, *job); err != nil {
				return false, err
			}
		}
	}
	// Keep the last decision as review context, including for databases that
	// recorded planning history before decision metadata was retained.
	if job.State != Observed && len(job.Plan) != 0 {
		if err := rememberPlanning(tx, *job); err != nil {
			return false, err
		}
	}
	changed := job.PlanningFingerprint != observed.PlanningFingerprint
	job.PlanningFingerprint = observed.PlanningFingerprint
	return changed, nil
}

func restorePlanning(tx *gorm.DB, job *Job) error {
	if job.PlanningFingerprint == "" {
		return nil
	}
	var result PlanningResult
	err := tx.Where(&PlanningResult{
		JobID: job.ID, Fingerprint: job.PlanningFingerprint, Revision: job.Revision,
	}, "JobID", "Fingerprint", "Revision").First(&result).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	job.PlanningAttempts = result.Attempts
	job.RetryAt = result.RetryAt
	job.Reason = result.Reason
	if result.Complete {
		job.State = Blocked
		job.Reason = "these inputs were already planned; request reconsideration to try again"
		// This is context for an operator answer, never an executable ready plan.
		job.Plan = result.Plan
	}
	return nil
}

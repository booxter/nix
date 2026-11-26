package jobs

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/planning"
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
	Plan        json.RawMessage  `gorm:"serializer:json"`
	PlanResult  *planning.Result `gorm:"serializer:json"`
}

func rememberPlanning(tx *gorm.DB, job Job) error {
	if job.PlanningFingerprint == "" {
		return fmt.Errorf("job has no planning input identity")
	}
	result := PlanningResult{
		JobID: job.ID, Fingerprint: job.PlanningFingerprint, Revision: job.Revision,
		Complete: job.State != Observed, Attempts: job.PlanningAttempts,
		RetryAt: job.RetryAt, Reason: job.Reason, Plan: job.Plan, PlanResult: job.PlanResult,
	}
	return tx.Clauses(clause.OnConflict{UpdateAll: true}).Create(&result).Error
}

func (store *Store) planningInputs(job Job) (planning.Inputs, error) {
	inputs, err := store.project(job.Service, job.Evidence)
	if err != nil {
		return planning.Inputs{}, fmt.Errorf("project %s planning inputs: %w", job.Service, err)
	}
	if inputs.Fingerprint() == "" {
		return planning.Inputs{}, fmt.Errorf("%s planning inputs are missing", job.Service)
	}
	return inputs, nil
}

func (store *Store) observePlanning(tx *gorm.DB, job *Job, observed Job) (bool, []string, error) {
	current, err := store.planningInputs(observed)
	if err != nil {
		return false, nil, err
	}
	var previous planning.Inputs
	if len(job.Evidence) != 0 {
		previous, err = store.planningInputs(*job)
		if err != nil {
			return false, nil, err
		}
	}
	if job.PlanningFingerprint == "" {
		// Bootstrap from stored evidence, not the latest assessment. Existing
		// blocked jobs retain their decision when the new identity is introduced.
		job.PlanningFingerprint = previous.Fingerprint()
		if job.PlanningFingerprint != "" && (job.State != Observed || job.PlanningAttempts > 0) {
			if err := rememberPlanning(tx, *job); err != nil {
				return false, nil, err
			}
		}
	}
	// Keep the last decision as review context, including for databases that
	// recorded planning history before decision metadata was retained.
	if job.State != Observed && len(job.Plan) != 0 {
		if err := rememberPlanning(tx, *job); err != nil {
			return false, nil, err
		}
	}
	changed := job.PlanningFingerprint != current.Fingerprint()
	job.PlanningFingerprint = current.Fingerprint()
	return changed, current.Changes(previous), nil
}

func restorePlanning(tx *gorm.DB, job *Job) error {
	if job.PlanningFingerprint == "" {
		return fmt.Errorf("job has no planning input identity")
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
		job.Outcome = OutcomeAlreadyReviewed
		job.Reason = "these inputs were already planned; request reconsideration to try again"
		// This is context for an operator answer, never an executable ready plan.
		job.Plan = result.Plan
		job.PlanResult = result.PlanResult
	}
	return nil
}

package statemigration

import (
	"encoding/json"
	"path/filepath"
	"sort"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
)

func restorePlan(directory string, current *convertedCase) error {
	result, found, err := readJSON[planning.StoredResult](recordPath(filepath.Join(directory, "planning"), current.id))
	if err != nil || !found {
		return err
	}
	applyPlanningResult(&current.job, result)
	return nil
}

func applyPlanningResult(job *jobs.Job, result planning.StoredResult) {
	job.PlanningAttempts = int(result.Attempts)
	if result.AttemptedAt.After(job.UpdatedAt) {
		job.UpdatedAt = result.AttemptedAt
	}
	if result.RetryAfter != nil {
		job.RetryAt = *result.RetryAfter
	}
	if result.Failure != nil {
		job.Reason = string(result.Failure.Kind)
	}
	if len(result.Decision) == 0 {
		return
	}

	job.Plan = result.Decision
	job.PendingAction = ""
	job.State = jobs.Ready
	var decision struct {
		Action      string `json:"action"`
		Explanation string `json:"explanation"`
	}
	// The original planner result is retained byte-for-byte for audit.
	_ = json.Unmarshal(result.Decision, &decision)
	if decision.Action == "no_repair" {
		job.State = jobs.Blocked
		job.Reason = decision.Explanation
	}
}

func restoreGuidance(root, directory string, service jobs.Service, cases map[string]*convertedCase) error {
	requests, err := readDirectory[reconsideration.Request](filepath.Join(root, "media-repair-reconsideration", string(service)))
	if err != nil {
		return err
	}
	sort.Slice(requests, func(i, j int) bool {
		return requests[i].CreatedAt.Before(requests[j].CreatedAt)
	})
	for _, request := range requests {
		current := cases[request.CaseID]
		if current == nil {
			continue
		}
		job := &current.job
		job.Guidance = request.Guidance
		job.RuntimeToleranceMS = 0
		if request.PolicyOverrides != nil {
			job.RuntimeToleranceMS = request.PolicyOverrides.MaximumRuntimeDifferenceMS
		}
		if current.attempt != nil && (current.attempt.State == jobs.Imported ||
			!request.CreatedAt.After(current.attempt.StartedAt)) {
			continue
		}
		job.State = jobs.Observed
		job.PendingAction = jobs.Reconsider
		job.UpdatedAt = request.CreatedAt

		result, found, err := readJSON[reconsideration.Result](recordPath(filepath.Join(directory, "reconsiderations"), request.RequestID))
		if err != nil {
			return err
		}
		if found {
			applyPlanningResult(job, result.Outcome)
		}
	}
	return nil
}

package repairui

import (
	"encoding/json"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/repairlidarr"
	"github.com/booxter/nix-config/media-repair/internal/repairradarr"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

// The inbox and the API must offer the same question, including for jobs
// that stopped during execution or were saved by an older daemon.
func reviewFor(job jobs.Job) review {
	var plan decision
	_ = json.Unmarshal(job.Plan, &plan)
	outcome := classifyOutcome(job, plan)
	question := attentionFor(job, plan, outcome)
	canAct := job.AcceptsActions()
	return review{
		Decision: plan, Outcome: outcome, Attention: question,
		Actions: availableActions{
			"answer":     question != nil,
			"remove":     canAct,
			"reconsider": canAct && question == nil && job.State != jobs.Imported,
		},
	}
}

func attentionFor(job jobs.Job, plan decision, outcome jobs.Outcome) *planning.Question {
	if !job.InQueue || job.PendingAction != "" || job.CollectionError != "" || len(job.Findings) > 0 ||
		(job.State != jobs.Blocked && job.State != jobs.Failed) || outcome == jobs.OutcomeEvidenceChanged {
		return nil
	}
	if job.AttemptQuestion != nil {
		return job.AttemptQuestion
	}
	if job.PlanResult != nil && outcome != jobs.OutcomeInterrupted && outcome != jobs.OutcomeRuntimeMismatch {
		return job.PlanResult.Question
	}
	return legacyQuestion(job, plan, outcome)
}

// Older daemons saved the stop reason without its question. Rebuild it for
// jobs that were already waiting for an answer at upgrade time.
func legacyQuestion(job jobs.Job, plan decision, outcome jobs.Outcome) *planning.Question {
	var evidence struct {
		Case json.RawMessage `json:"case"`
	}
	if json.Unmarshal(job.Evidence, &evidence) != nil || len(evidence.Case) == 0 || string(evidence.Case) == "null" || string(evidence.Case) == "{}" {
		return nil
	}
	switch outcome {
	case jobs.OutcomeInterrupted:
		return planning.ResumeRepair()
	case jobs.OutcomeRuntimeMismatch:
		if job.Service == jobs.Radarr {
			return movieQuestion(evidence.Case, "runtime_mismatch", nil)
		}
		return nil
	case jobs.OutcomePlannerFailed:
		return planning.RetryPlanning()
	}

	if plan.Action == "no_repair" {
		switch job.Service {
		case jobs.Radarr:
			return movieQuestion(evidence.Case, plan.Reason, plan.MissingEvidence)
		case jobs.Lidarr:
			var album lidarrcontracts.Case
			if json.Unmarshal(evidence.Case, &album) == nil {
				return repairlidarr.Question(album, plan.Reason)
			}
		}
	}
	return nil
}

func movieQuestion(data json.RawMessage, reason string, missing []contracts.MissingEvidence) *planning.Question {
	var movie contracts.RepairCaseV3
	if json.Unmarshal(data, &movie) != nil {
		return nil
	}
	return repairradarr.Question(movie, reason, missing)
}

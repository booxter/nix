package repairradarr

import (
	"context"
	"encoding/json"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/repair"
)

type Planner interface {
	PlanRadarr(context.Context, contracts.RepairCaseV3, planning.Options) (contracts.RepairDecisionV3, error)
}

func readPlanningCase(data json.RawMessage) (contracts.RepairCaseV3, error) {
	var evidence Evidence
	if err := json.Unmarshal(data, &evidence); err != nil {
		return contracts.RepairCaseV3{}, err
	}
	return evidence.Case, nil
}

func (adapter *Adapter) Plan(ctx context.Context, job jobs.Job) (repair.Decision, error) {
	repairCase, err := readPlanningCase(job.Evidence)
	if err != nil {
		return repair.Decision{}, err
	}

	decision, err := adapter.Planner.PlanRadarr(ctx, repairCase, repair.Guidance(job))
	if err != nil {
		return repair.Decision{}, err
	}

	data, err := contracts.EncodeDecision(decision)
	if stop := decision.NoRepair; stop != nil {
		code := string(stop.Reason)
		question := Question(repairCase, code, stop.MissingEvidence)
		return repair.PlannerStop(data, code, stop.Explanation, question), err
	}
	return repair.Decision{Data: data, Result: planning.Result{Outcome: planning.Repair}}, err
}

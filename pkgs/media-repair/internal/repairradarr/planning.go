package repairradarr

import (
	"context"
	"encoding/json"
	"slices"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
	"github.com/booxter/nix-config/media-repair/internal/radarr"
	"github.com/booxter/nix-config/media-repair/internal/repair"
)

type Planner interface {
	PlanRadarr(context.Context, contracts.RepairCaseV3, planning.Options) (contracts.RepairDecisionV3, error)
}

func (adapter *Adapter) Observe(ctx context.Context, saved []jobs.Job) (repair.Observation, error) {
	return repair.QueuePoll[controller.RadarrQueueRecord, casebuilder.Assembly]{
		ReadQueue: adapter.Client.ReadQueue,
		FindComplete: func(ctx context.Context, queue []controller.RadarrQueueRecord) ([]queuefinalize.Entry, error) {
			return radarr.FinalizationCandidates(ctx, adapter.Client, queue)
		},
		NewJob: func(entry controller.RadarrQueueRecord) jobs.Job {
			return jobs.Job{QueueID: entry.ID, DownloadID: entry.DownloadID, Title: entry.Title}
		},
		Inspect: func(ctx context.Context, entry controller.RadarrQueueRecord, _ json.RawMessage) CollectionResult {
			return adapter.Inspector.Inspect(ctx, entry)
		},
		StopReason: movieStopReason,
		EncodeCase: encodeCase,
	}.Observe(ctx, saved)
}

func movieStopReason(result CollectionResult) jobs.Outcome {
	if slices.Contains(result.Findings, string(controller.CandidateIncompleteDownload)) {
		return jobs.OutcomeIncompleteDownload
	}
	return jobs.OutcomeOther
}

func encodeCase(assembly casebuilder.Assembly) (jobs.InspectedCase, error) {
	data, err := json.Marshal(Evidence{Case: assembly.Request, Snapshot: assembly.LocalSnapshot})
	return jobs.InspectedCase{Fingerprint: assembly.Request.CaseID, Evidence: data}, err
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

func (adapter *Adapter) Ready(job jobs.Job) bool {
	var evidence Evidence
	if err := json.Unmarshal(job.Evidence, &evidence); err != nil {
		return false
	}

	queue := evidence.Snapshot.Observation.Correlation.Radarr
	return queue.TrackedDownloadState != "importPending" || adapter.Now().Sub(job.StableSince) >= adapter.Stabilization
}

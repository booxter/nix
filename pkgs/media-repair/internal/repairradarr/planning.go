package repairradarr

import (
	"context"
	"encoding/json"
	"slices"
	"strings"

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
	Plan(context.Context, contracts.RepairCaseV3, planning.Options) (contracts.RepairDecisionV3, error)
}

func (adapter *Adapter) Observe(ctx context.Context, saved []jobs.Job) (repair.Observation, error) {
	return repair.QueuePoll[controller.RadarrQueueRecord]{
		ReadQueue: adapter.Client.ReadQueue,
		FindComplete: func(ctx context.Context, queue []controller.RadarrQueueRecord) ([]queuefinalize.Entry, error) {
			return radarr.FinalizationCandidates(ctx, adapter.Client, queue)
		},
		NewJob: func(entry controller.RadarrQueueRecord) jobs.Job {
			return jobs.Job{QueueID: entry.ID, DownloadID: entry.DownloadID, Title: entry.Title}
		},
		Inspect: adapter.inspectJob,
	}.Observe(ctx, saved)
}

// Keep skipped entries visible in the inbox. Only a collected case has
// evidence that the scheduler can send to the planner.
func (adapter *Adapter) inspectJob(ctx context.Context, entry controller.RadarrQueueRecord, _ json.RawMessage, job *jobs.Job) error {
	result := adapter.Inspector.Inspect(ctx, entry)
	switch {
	case result.Err != nil:
		job.CollectionError = result.Err.Error()
		job.CollectionOutcome = jobs.OutcomeOther
	case len(result.Findings) > 0:
		job.CollectionError = strings.Join(result.Findings, ", ")
		job.CollectionOutcome = jobs.OutcomeOther
		if slices.Contains(result.Findings, string(controller.CandidateIncompleteDownload)) {
			job.CollectionOutcome = jobs.OutcomeIncompleteDownload
		}
	default:
		current, err := encodeCase(*result.Case)
		if err != nil {
			return err
		}
		job.SourceFingerprint, job.Evidence = current.Fingerprint, current.Evidence
	}
	return nil
}

func encodeCase(assembly casebuilder.Assembly) (jobs.InspectedCase, error) {
	data, err := json.Marshal(Evidence{Case: assembly.Request, Snapshot: assembly.LocalSnapshot})
	return jobs.InspectedCase{Fingerprint: assembly.Request.CaseID, Evidence: data}, err
}

func (adapter *Adapter) Plan(ctx context.Context, job jobs.Job) (repair.Decision, error) {
	var evidence Evidence
	if err := json.Unmarshal(job.Evidence, &evidence); err != nil {
		return repair.Decision{}, err
	}

	decision, err := adapter.Planner.Plan(ctx, evidence.Case, repair.Guidance(job))
	if err != nil {
		return repair.Decision{}, err
	}

	data, err := contracts.EncodeDecision(decision)
	result := repair.Decision{Data: data, Result: planning.Result{Outcome: planning.Repair}}
	if stop := decision.NoRepair; stop != nil {
		result.Reason = string(stop.Reason)
		result.Result = planning.NoRepair(result.Reason, Question(evidence.Case, result.Reason, stop.MissingEvidence))
	}

	return result, err
}

func (adapter *Adapter) Ready(job jobs.Job) bool {
	var evidence Evidence
	if err := json.Unmarshal(job.Evidence, &evidence); err != nil {
		return false
	}

	queue := evidence.Snapshot.Observation.Correlation.Radarr
	return queue.TrackedDownloadState != "importPending" || adapter.Now().Sub(job.StableSince) >= adapter.Stabilization
}

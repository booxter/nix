package repairradarr

import (
	"context"
	"encoding/json"
	"slices"
	"strings"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/radarr"
	"github.com/booxter/nix-config/media-repair/internal/repair"
)

type Planner interface {
	Plan(context.Context, contracts.RepairCaseV3, planning.Options) (contracts.RepairDecisionV3, error)
}

func (adapter *Adapter) Observe(ctx context.Context, _ []jobs.Job) (repair.Observation, error) {
	queue, err := adapter.Client.ReadQueue(ctx)
	if err != nil {
		return repair.Observation{}, err
	}

	observed := repair.Observation{}
	complete, err := radarr.FinalizationCandidates(ctx, adapter.Client, queue)
	if err != nil {
		return repair.Observation{}, err
	}
	for _, entry := range complete {
		observed.Complete = append(observed.Complete, jobs.QueueKey{QueueID: entry.QueueID, DownloadID: entry.DownloadID})
	}
	// Cleanup and case collection share the same queue snapshot for this poll.
	for _, entry := range queue {
		observed.Queue = append(observed.Queue, jobs.QueueKey{QueueID: entry.ID, DownloadID: entry.DownloadID})
		result := adapter.Inspector.Inspect(ctx, entry)
		if err := ctx.Err(); err != nil {
			return repair.Observation{}, err
		}
		job, err := observedJob(entry, result)
		if err != nil {
			return repair.Observation{}, err
		}
		observed.Jobs = append(observed.Jobs, job)
	}

	return observed, nil
}

// Keep skipped entries visible in the inbox. Only a collected case has
// evidence that the scheduler can send to the planner.
func observedJob(entry controller.RadarrQueueRecord, result CollectionResult) (jobs.Job, error) {
	job := jobs.Job{QueueID: entry.ID, DownloadID: entry.DownloadID, Title: entry.Title}
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
		assembly := result.Case
		job.SourceFingerprint = assembly.Request.CaseID
		data, err := json.Marshal(Evidence{Case: assembly.Request, Snapshot: assembly.LocalSnapshot})
		if err != nil {
			return jobs.Job{}, err
		}
		job.Evidence = data
	}
	return job, nil
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
	result := repair.Decision{Data: data, Repair: decision.Kind != contracts.ActionNoRepair}
	if decision.NoRepair != nil {
		result.Reason = string(decision.NoRepair.Reason)
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

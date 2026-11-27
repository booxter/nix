package repairradarr

import (
	"context"
	"encoding/json"
	"slices"

	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
	"github.com/booxter/nix-config/media-repair/internal/radarr"
	"github.com/booxter/nix-config/media-repair/internal/repair"
)

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

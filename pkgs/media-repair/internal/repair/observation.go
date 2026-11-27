package repair

import (
	"context"
	"encoding/json"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/pipeline"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
)

type Observation struct {
	Jobs     []jobs.Job
	Complete []jobs.QueueKey
}

type QueuePoll[Entry, Case any] struct {
	ReadQueue    func(context.Context) ([]Entry, error)
	FindComplete func(context.Context, []Entry) ([]queuefinalize.Entry, error)
	NewJob       func(Entry) jobs.Job
	Inspect      func(context.Context, Entry, json.RawMessage) pipeline.Result[Case]
	StopReason   func(pipeline.Result[Case]) jobs.Outcome
	EncodeCase   func(Case) (jobs.InspectedCase, error)
}

// Cleanup and inspection use the same queue snapshot. Keep every row visible,
// including jobs that have already moved past inspection.
func (poll QueuePoll[Entry, Case]) Observe(ctx context.Context, saved []jobs.Job) (Observation, error) {
	queue, err := poll.ReadQueue(ctx)
	if err != nil {
		return Observation{}, err
	}
	complete, err := poll.FindComplete(ctx, queue)
	if err != nil {
		return Observation{}, err
	}
	var observed Observation
	for _, entry := range complete {
		observed.Complete = append(observed.Complete, jobs.QueueKey{QueueID: entry.QueueID, DownloadID: entry.DownloadID})
	}
	for _, entry := range queue {
		observed.Jobs = append(observed.Jobs, poll.NewJob(entry))
	}

	previous, err := jobs.MatchSavedJobs(saved, jobs.QueueKeys(observed.Jobs))
	if err != nil {
		return Observation{}, err
	}
	for i, entry := range queue {
		if err := ctx.Err(); err != nil {
			return Observation{}, err
		}
		job := &observed.Jobs[i]
		prior := previous[job.QueueKey()]
		switch prior.State {
		case jobs.Running, jobs.Importing, jobs.Imported:
			continue
		}
		result := poll.Inspect(ctx, entry, prior.Evidence)
		if err := poll.recordInspection(job, result); err != nil {
			return Observation{}, err
		}
	}
	return observed, ctx.Err()
}

// Only a collected case goes to the planner. Keep every validator finding,
// or the error that prevented inspection, alongside the queue entry.
func (poll QueuePoll[Entry, Case]) recordInspection(job *jobs.Job, result pipeline.Result[Case]) error {
	if result.Case == nil {
		job.CollectionOutcome = poll.StopReason(result)
		job.Findings = result.Findings
		if result.Err != nil {
			job.CollectionError = result.Err.Error()
		}
		return nil
	}

	current, err := poll.EncodeCase(*result.Case)
	if err != nil {
		return err
	}
	job.SourceFingerprint, job.Evidence = current.Fingerprint, current.Evidence
	return nil
}

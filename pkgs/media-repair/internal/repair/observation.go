package repair

import (
	"context"
	"encoding/json"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
)

type Observation struct {
	Jobs     []jobs.Job
	Complete []jobs.QueueKey
}

type QueuePoll[Entry any] struct {
	ReadQueue    func(context.Context) ([]Entry, error)
	FindComplete func(context.Context, []Entry) ([]queuefinalize.Entry, error)
	NewJob       func(Entry) jobs.Job
	Inspect      func(context.Context, Entry, json.RawMessage, *jobs.Job) error
}

// Cleanup and inspection use the same queue snapshot. Keep every row visible,
// including jobs that have already moved past inspection.
func (poll QueuePoll[Entry]) Observe(ctx context.Context, saved []jobs.Job) (Observation, error) {
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
		if err := poll.Inspect(ctx, entry, prior.Evidence, job); err != nil {
			return Observation{}, err
		}
	}
	return observed, ctx.Err()
}

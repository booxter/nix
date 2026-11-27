package repair

import (
	"context"
	"encoding/json"
	"slices"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

// Each service supplies two steps. The type returned by Authorize is the
// input to PrepareImport, so a movie can carry a remux plan and an album
// can carry the selected tracks.
type ImportSteps[Approved any] struct {
	Authorize     func(context.Context, jobs.Job, json.RawMessage) (Approved, error)
	PrepareImport func(context.Context, jobs.Attempt, Approved) (PreparedImport, error)
}

// The engine can run either service's steps without knowing its media types.
type ImportFlow interface {
	prepare(context.Context, jobs.Job, jobs.Attempt) (PreparedImport, error)
}

func (steps ImportSteps[Approved]) prepare(ctx context.Context, job jobs.Job, attempt jobs.Attempt) (PreparedImport, error) {
	approved, err := steps.Authorize(ctx, job, attempt.Plan)
	if err != nil {
		return PreparedImport{}, err
	}
	return steps.PrepareImport(ctx, attempt, approved)
}

// Recheck the queue before acting on a saved job. A temporary read failure
// can be retried. A missing or ambiguous download must stop the repair.
func ReadQueueEntry[Entry any](
	ctx context.Context,
	key jobs.QueueKey,
	readQueue func(context.Context) ([]Entry, error),
	keyOf func(Entry) jobs.QueueKey,
) (Entry, error) {
	var zero Entry
	entries, err := readQueue(ctx)
	if err != nil {
		return zero, RetryableRead(err)
	}

	keys := make([]jobs.QueueKey, len(entries))
	for i, entry := range entries {
		keys[i] = keyOf(entry)
	}
	index, err := jobs.MatchQueue(key, keys)
	if err != nil {
		return zero, &BlockedError{Reason: err.Error()}
	}
	if index < 0 {
		return zero, &BlockedError{Reason: "download is no longer queued"}
	}
	return entries[index], nil
}

// A queued download can become ineligible while its plan waits to run.
// Keep the inspection findings as the operator-visible reason for stopping.
func CheckEligibility(findings []string) error {
	if len(findings) == 0 {
		return nil
	}
	return &BlockedError{Reason: strings.Join(findings, ", "), Code: eligibilityOutcome(findings)}
}

// A download still in progress can become eligible on a later poll.
func eligibilityOutcome(findings []string) jobs.Outcome {
	if slices.Contains(findings, string(jobs.OutcomeIncompleteDownload)) {
		return jobs.OutcomeIncompleteDownload
	}
	return jobs.OutcomeQueueNotReady
}

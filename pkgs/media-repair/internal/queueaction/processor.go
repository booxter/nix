package queueaction

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
)

type Finalizer interface {
	Finalize(context.Context, queuefinalize.Entry) (queuefinalize.Outcome, error)
}

type Processor struct {
	results   *ResultStore
	finalizer Finalizer
	now       func() time.Time
}

func NewProcessor(
	results *ResultStore,
	finalizer Finalizer,
	now func() time.Time,
) (*Processor, error) {
	if results == nil || finalizer == nil || now == nil {
		return nil, fmt.Errorf("queue action processor dependencies are incomplete")
	}
	return &Processor{results: results, finalizer: finalizer, now: now}, nil
}

func (processor *Processor) Process(
	ctx context.Context,
	request Request,
) (Result, error) {
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	previous, found, err := processor.results.Get(request)
	if err != nil {
		return Result{}, err
	}
	if found && previous.State == StateCompleted {
		return previous, nil
	}
	attemptedAt := processor.now().UTC()
	if attemptedAt.IsZero() {
		return Result{}, fmt.Errorf("queue action clock returned a zero time")
	}
	attempts := uint64(1)
	if found {
		attempts = previous.Attempts + 1
	}
	outcome, finalizeErr := processor.finalizer.Finalize(ctx, request.Queue.Entry())
	result := Result{
		Version: resultVersion, RequestID: request.RequestID,
		Attempts: attempts, AttemptedAt: attemptedAt,
	}
	if finalizeErr != nil {
		result.State = StateFailed
		result.Failure = "remove_failed"
	} else if outcome == queuefinalize.OutcomeIdentityChanged {
		result.State = StateFailed
		result.Failure = "queue_identity_changed"
	} else {
		result.State = StateCompleted
		result.Outcome = string(outcome)
	}
	if err := processor.results.Put(request, result); err != nil {
		return result, err
	}
	if finalizeErr != nil {
		return result, fmt.Errorf("remove queue tracking: %w", finalizeErr)
	}
	return result, nil
}

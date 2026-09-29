package queueaction

import (
	"context"
	"errors"
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
	if found && previous.Failure == "queue_identity_changed" {
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

type Processed struct {
	Request Request
	Result  Result
}

func ProcessLatest(
	ctx context.Context,
	requests *Store,
	processor *Processor,
) ([]Processed, error) {
	if requests == nil || processor == nil {
		return nil, fmt.Errorf("queue action processing is not configured")
	}
	stored, err := requests.List()
	if err != nil {
		return nil, err
	}
	seen := make(map[string]struct{}, len(stored))
	processed := make([]Processed, 0, len(stored))
	var failures []error
	for _, request := range stored {
		if _, found := seen[request.CaseID]; found {
			continue
		}
		seen[request.CaseID] = struct{}{}
		result, processErr := processor.Process(ctx, request)
		processed = append(processed, Processed{Request: request, Result: result})
		if processErr != nil {
			failures = append(failures, fmt.Errorf("case %s: %w", request.CaseID, processErr))
		}
	}
	return processed, errors.Join(failures...)
}

func LoadLatest(requests *Store, results *ResultStore) ([]Processed, error) {
	if requests == nil || results == nil {
		return nil, fmt.Errorf("queue action results are not configured")
	}
	stored, err := requests.List()
	if err != nil {
		return nil, err
	}
	seen := make(map[string]struct{}, len(stored))
	processed := make([]Processed, 0, len(stored))
	for _, request := range stored {
		if _, found := seen[request.CaseID]; found {
			continue
		}
		seen[request.CaseID] = struct{}{}
		result, found, err := results.Get(request)
		if err != nil {
			return nil, err
		}
		if found {
			processed = append(processed, Processed{Request: request, Result: result})
		}
	}
	return processed, nil
}

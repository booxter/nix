package reconsideration

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/planning"
)

type PlanFunc func(context.Context, Request, json.RawMessage) (json.RawMessage, error)
type ClassifyFailure func(error) planning.Failure

type Processor struct {
	results  *ResultStore
	plan     PlanFunc
	now      func() time.Time
	classify ClassifyFailure
	backoff  planning.Backoff
}

func NewProcessor(
	results *ResultStore,
	plan PlanFunc,
	now func() time.Time,
	classify ClassifyFailure,
	backoff planning.Backoff,
) (*Processor, error) {
	switch {
	case results == nil:
		return nil, fmt.Errorf("reconsideration result store is required")
	case plan == nil:
		return nil, fmt.Errorf("reconsideration planner is required")
	case now == nil:
		return nil, fmt.Errorf("reconsideration clock is required")
	case classify == nil:
		return nil, fmt.Errorf("reconsideration failure classifier is required")
	case backoff.Initial <= 0 || backoff.Maximum < backoff.Initial:
		return nil, fmt.Errorf("reconsideration retry policy is invalid")
	}
	return &Processor{
		results: results, plan: plan, now: now, classify: classify, backoff: backoff,
	}, nil
}

// Process returns the active revised decision. A pending or failed latest
// request deliberately returns no decision, preventing the prior decision from
// being executed while reconsideration is outstanding.
func (processor *Processor) Process(
	ctx context.Context,
	request Request,
	prior json.RawMessage,
) (json.RawMessage, Result, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, Result{}, false, err
	}
	stored, found, err := processor.results.Get(request)
	if err != nil {
		return nil, Result{}, false, err
	}
	if found && stored.Outcome.HasDecision() {
		return append(json.RawMessage(nil), stored.Outcome.Decision...), stored, true, nil
	}
	now := processor.now().UTC()
	if now.IsZero() {
		return nil, stored, false, fmt.Errorf("reconsideration clock returned a zero time")
	}
	if found && stored.Outcome.RetryAfter != nil && now.Before(*stored.Outcome.RetryAfter) {
		return nil, stored, false, nil
	}
	decision, planErr := processor.plan(ctx, request, prior)
	completedAt := processor.now().UTC()
	if completedAt.IsZero() {
		return nil, stored, false, fmt.Errorf("reconsideration clock returned a zero time")
	}
	if planErr != nil {
		attempts := uint64(0)
		if found {
			attempts = stored.Outcome.Attempts
		}
		retryAfter := completedAt.Add(processor.backoff.Delay(attempts))
		failure := processor.classify(planErr)
		failed, _, storeErr := processor.results.PutFailure(
			request, failure, completedAt, retryAfter,
		)
		if storeErr != nil {
			return nil, failed, false, errors.Join(planErr, storeErr)
		}
		return nil, failed, false, fmt.Errorf("reconsideration planner failed: %w", planErr)
	}
	result, _, err := processor.results.PutDecision(request, decision, completedAt)
	if err != nil {
		return nil, result, false, err
	}
	return append(json.RawMessage(nil), result.Outcome.Decision...), result, true, nil
}

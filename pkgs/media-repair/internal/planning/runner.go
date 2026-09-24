package planning

import (
	"context"
	"errors"
	"fmt"
	"time"
)

type Clock interface {
	Now() time.Time
}

type Status struct {
	Attempts   uint64
	RetryAfter *time.Time
	Decided    bool
}

type Planned[Case, Decision any] struct {
	Case     Case
	Decision Decision
}

type Store[Case, Decision, Failure any] interface {
	PutCase(Case) (bool, error)
	GetStatus(string) (Status, bool, error)
	GetPlanned(string) (Planned[Case, Decision], error)
	PutFailure(string, Failure, time.Time, time.Time) (Status, bool, error)
	PutDecision(string, Decision, time.Time) (Status, bool, error)
}

type Backoff struct {
	Initial time.Duration
	Maximum time.Duration
}

type Dependencies[Case, Decision, Failure any] struct {
	Store           Store[Case, Decision, Failure]
	Plan            func(context.Context, Case) (Decision, error)
	Clock           Clock
	CaseID          func(Case) string
	DecisionCaseID  func(Decision) string
	Superseded      func(Case) bool
	ClassifyFailure func(error) Failure
	Backoff         Backoff
}

type Outcome uint8

const (
	Failed Outcome = iota + 1
	Decided
	AlreadyDecided
	Deferred
	Superseded
)

type Result[Case, Decision, Failure any] struct {
	Outcome         Outcome
	Stored          bool
	Submitted       bool
	Planned         Planned[Case, Decision]
	Failure         *Failure
	PlannerDuration time.Duration
}

type Runner[Case, Decision, Failure any] struct {
	dependencies Dependencies[Case, Decision, Failure]
}

func New[Case, Decision, Failure any](
	dependencies Dependencies[Case, Decision, Failure],
) (*Runner[Case, Decision, Failure], error) {
	switch {
	case dependencies.Store == nil:
		return nil, fmt.Errorf("planning result store is required")
	case dependencies.Plan == nil:
		return nil, fmt.Errorf("planner is required")
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("clock is required")
	case dependencies.CaseID == nil:
		return nil, fmt.Errorf("case identity function is required")
	case dependencies.DecisionCaseID == nil:
		return nil, fmt.Errorf("decision identity function is required")
	case dependencies.Superseded == nil:
		return nil, fmt.Errorf("supersession function is required")
	case dependencies.ClassifyFailure == nil:
		return nil, fmt.Errorf("planner failure classifier is required")
	case dependencies.Backoff.Initial <= 0:
		return nil, fmt.Errorf("initial planner retry delay must be positive")
	case dependencies.Backoff.Maximum < dependencies.Backoff.Initial:
		return nil, fmt.Errorf("maximum planner retry delay must not be shorter than the initial delay")
	default:
		return &Runner[Case, Decision, Failure]{dependencies: dependencies}, nil
	}
}

func (runner *Runner[Case, Decision, Failure]) Process(
	ctx context.Context,
	current Case,
) (Result[Case, Decision, Failure], error) {
	if runner == nil {
		return Result[Case, Decision, Failure]{}, fmt.Errorf("planning runner is not configured")
	}
	if err := ctx.Err(); err != nil {
		return Result[Case, Decision, Failure]{}, err
	}
	created, err := runner.dependencies.Store.PutCase(current)
	if err != nil {
		return Result[Case, Decision, Failure]{Outcome: Failed}, fmt.Errorf(
			"store repair case: %w", err,
		)
	}
	result := Result[Case, Decision, Failure]{
		Stored:  created,
		Planned: Planned[Case, Decision]{Case: current},
	}
	if runner.dependencies.Superseded(current) {
		result.Outcome = Superseded
		return result, nil
	}

	caseID := runner.dependencies.CaseID(current)
	if caseID == "" {
		result.Outcome = Failed
		return result, fmt.Errorf("repair case identity is empty")
	}
	previous, found, err := runner.dependencies.Store.GetStatus(caseID)
	if err != nil {
		result.Outcome = Failed
		return result, fmt.Errorf("read planning result: %w", err)
	}
	if found && previous.Decided {
		return runner.loadPlanned(caseID, result, AlreadyDecided)
	}

	now := runner.dependencies.Clock.Now().UTC()
	if now.IsZero() {
		result.Outcome = Failed
		return result, fmt.Errorf("clock returned a zero time")
	}
	if found && previous.RetryAfter != nil && now.Before(*previous.RetryAfter) {
		result.Outcome = Deferred
		return result, nil
	}

	result.Submitted = true
	decision, planErr := runner.dependencies.Plan(ctx, current)
	completedAt := runner.dependencies.Clock.Now().UTC()
	if completedAt.IsZero() {
		result.Outcome = Failed
		return result, fmt.Errorf("clock returned a zero time")
	}
	if completedAt.After(now) {
		result.PlannerDuration = completedAt.Sub(now)
	}
	if planErr != nil {
		priorAttempts := uint64(0)
		if found {
			priorAttempts = previous.Attempts
		}
		retryAfter := completedAt.Add(runner.dependencies.Backoff.Delay(priorAttempts))
		failure := runner.dependencies.ClassifyFailure(planErr)
		result.Failure = &failure
		_, _, storeErr := runner.dependencies.Store.PutFailure(
			caseID, failure, completedAt, retryAfter,
		)
		result.Outcome = Failed
		if storeErr != nil {
			return result, errors.Join(
				fmt.Errorf("planner failed: %w", planErr),
				fmt.Errorf("store planner failure: %w", storeErr),
			)
		}
		return result, fmt.Errorf("planner failed: %w", planErr)
	}
	if decisionCaseID := runner.dependencies.DecisionCaseID(decision); decisionCaseID != caseID {
		result.Outcome = Failed
		return result, fmt.Errorf(
			"planning decision case ID %q does not match observed case %q",
			decisionCaseID, caseID,
		)
	}
	stored, changed, err := runner.dependencies.Store.PutDecision(caseID, decision, completedAt)
	if err != nil {
		result.Outcome = Failed
		return result, fmt.Errorf("store planning decision: %w", err)
	}
	if !changed && stored.Decided {
		return runner.loadPlanned(caseID, result, AlreadyDecided)
	}
	if !changed {
		result.Outcome = Failed
		return result, fmt.Errorf("result store did not record the planning decision")
	}
	result.Planned.Decision = decision
	result.Outcome = Decided
	return result, nil
}

func (runner *Runner[Case, Decision, Failure]) loadPlanned(
	caseID string,
	result Result[Case, Decision, Failure],
	outcome Outcome,
) (Result[Case, Decision, Failure], error) {
	planned, err := runner.dependencies.Store.GetPlanned(caseID)
	if err != nil {
		result.Outcome = Failed
		return result, fmt.Errorf("load stored planned case: %w", err)
	}
	if decisionCaseID := runner.dependencies.DecisionCaseID(planned.Decision); decisionCaseID != caseID {
		result.Outcome = Failed
		return result, fmt.Errorf(
			"planning decision case ID %q does not match observed case %q",
			decisionCaseID, caseID,
		)
	}
	result.Planned = planned
	result.Outcome = outcome
	return result, nil
}

func (backoff Backoff) Delay(priorAttempts uint64) time.Duration {
	delay := backoff.Initial
	for priorAttempts > 0 && delay < backoff.Maximum {
		if delay > backoff.Maximum/2 {
			return backoff.Maximum
		}
		delay *= 2
		priorAttempts--
	}
	if delay > backoff.Maximum {
		return backoff.Maximum
	}
	return delay
}

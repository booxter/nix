package shadow

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

type CaseSource interface {
	InspectAll(context.Context) ([]casebuilder.Assembly, error)
}

type ResultStore interface {
	PutAssembly(casebuilder.Assembly) (bool, error)
	GetPlanningResult(string) (casestore.PlanningResult, bool, error)
	PutPlanningFailure(
		string,
		casestore.PlanningFailure,
		time.Time,
		time.Time,
	) (casestore.PlanningResult, bool, error)
	PutPlanningDecision(
		string,
		contracts.RepairDecisionV1,
		time.Time,
	) (casestore.PlanningResult, bool, error)
}

type FailureClassifier func(error) casestore.PlanningFailure

type Backoff struct {
	Initial time.Duration
	Maximum time.Duration
}

type Dependencies struct {
	Cases           CaseSource
	Store           ResultStore
	Planner         controller.Planner
	Clock           controller.Clock
	ClassifyFailure FailureClassifier
	Backoff         Backoff
}

type Report struct {
	Observed       int
	Stored         int
	Submitted      int
	Decided        int
	AlreadyDecided int
	Deferred       int
	Failed         int
}

type Runner struct {
	dependencies Dependencies
}

func New(dependencies Dependencies) (*Runner, error) {
	switch {
	case dependencies.Cases == nil:
		return nil, fmt.Errorf("case source is required")
	case dependencies.Store == nil:
		return nil, fmt.Errorf("result store is required")
	case dependencies.Planner == nil:
		return nil, fmt.Errorf("planner is required")
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("clock is required")
	case dependencies.ClassifyFailure == nil:
		return nil, fmt.Errorf("planner failure classifier is required")
	case dependencies.Backoff.Initial <= 0:
		return nil, fmt.Errorf("initial planner retry delay must be positive")
	case dependencies.Backoff.Maximum < dependencies.Backoff.Initial:
		return nil, fmt.Errorf("maximum planner retry delay must not be shorter than the initial delay")
	default:
		return &Runner{dependencies: dependencies}, nil
	}
}

func (runner *Runner) Run(ctx context.Context) (Report, error) {
	if runner == nil {
		return Report{}, fmt.Errorf("shadow runner is not configured")
	}
	if err := ctx.Err(); err != nil {
		return Report{}, err
	}

	assemblies, collectionErr := runner.dependencies.Cases.InspectAll(ctx)
	report := Report{Observed: len(assemblies)}
	runErrors := make([]error, 0, len(assemblies)+1)
	if collectionErr != nil {
		runErrors = append(runErrors, collectionErr)
	}
	for _, assembly := range assemblies {
		if err := ctx.Err(); err != nil {
			runErrors = append(runErrors, err)
			break
		}
		result, err := runner.process(ctx, assembly)
		report.add(result)
		if err != nil {
			runErrors = append(runErrors, fmt.Errorf(
				"process repair case %q: %w", assembly.Request.CaseID, err,
			))
		}
	}
	return report, errors.Join(runErrors...)
}

type caseOutcome uint8

const (
	caseFailed caseOutcome = iota + 1
	caseDecided
	caseAlreadyDecided
	caseDeferred
)

type caseResult struct {
	Outcome   caseOutcome
	Stored    bool
	Submitted bool
}

func (report *Report) add(result caseResult) {
	if result.Stored {
		report.Stored++
	}
	if result.Submitted {
		report.Submitted++
	}
	switch result.Outcome {
	case caseDecided:
		report.Decided++
	case caseAlreadyDecided:
		report.AlreadyDecided++
	case caseDeferred:
		report.Deferred++
	case caseFailed:
		report.Failed++
	}
}

func (runner *Runner) process(
	ctx context.Context,
	assembly casebuilder.Assembly,
) (caseResult, error) {
	created, err := runner.dependencies.Store.PutAssembly(assembly)
	if err != nil {
		return caseResult{Outcome: caseFailed}, fmt.Errorf("store repair case: %w", err)
	}
	result := caseResult{Stored: created}
	caseID := assembly.Request.CaseID
	previous, found, err := runner.dependencies.Store.GetPlanningResult(caseID)
	if err != nil {
		result.Outcome = caseFailed
		return result, fmt.Errorf("read planning result: %w", err)
	}
	if found && previous.HasDecision() {
		result.Outcome = caseAlreadyDecided
		return result, nil
	}
	now := runner.dependencies.Clock.Now().UTC()
	if now.IsZero() {
		result.Outcome = caseFailed
		return result, fmt.Errorf("clock returned a zero time")
	}
	if found && previous.RetryAfter != nil && now.Before(*previous.RetryAfter) {
		result.Outcome = caseDeferred
		return result, nil
	}

	result.Submitted = true
	decision, planErr := runner.dependencies.Planner.Plan(ctx, assembly.Request)
	completedAt := runner.dependencies.Clock.Now().UTC()
	if completedAt.IsZero() {
		result.Outcome = caseFailed
		return result, fmt.Errorf("clock returned a zero time")
	}
	if planErr != nil {
		priorAttempts := uint64(0)
		if found {
			priorAttempts = previous.Attempts
		}
		retryAfter := completedAt.Add(runner.dependencies.Backoff.delay(priorAttempts))
		failure := runner.dependencies.ClassifyFailure(planErr)
		_, _, storeErr := runner.dependencies.Store.PutPlanningFailure(
			caseID, failure, completedAt, retryAfter,
		)
		result.Outcome = caseFailed
		if storeErr != nil {
			return result, errors.Join(
				fmt.Errorf("planner failed: %w", planErr),
				fmt.Errorf("store planner failure: %w", storeErr),
			)
		}
		return result, fmt.Errorf("planner failed: %w", planErr)
	}

	stored, changed, err := runner.dependencies.Store.PutPlanningDecision(
		caseID, decision, completedAt,
	)
	if err != nil {
		result.Outcome = caseFailed
		return result, fmt.Errorf("store planning decision: %w", err)
	}
	if !changed && stored.HasDecision() {
		result.Outcome = caseAlreadyDecided
		return result, nil
	}
	if !changed {
		result.Outcome = caseFailed
		return result, fmt.Errorf("result store did not record the planning decision")
	}
	result.Outcome = caseDecided
	return result, nil
}

func (backoff Backoff) delay(priorAttempts uint64) time.Duration {
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

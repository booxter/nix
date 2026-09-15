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
	GetPlannedCase(string) (casestore.PlannedCase, error)
	GetPlanningResult(string) (casestore.PlanningResult, bool, error)
	PutPlanningFailure(
		string,
		casestore.PlanningFailure,
		time.Time,
		time.Time,
	) (casestore.PlanningResult, bool, error)
	PutPlanningDecision(
		string,
		contracts.RepairDecisionV2,
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
	Superseded     int
	Submitted      int
	Decided        int
	AlreadyDecided int
	Deferred       int
	Failed         int
	PlannedCases   []casestore.PlannedCase
	metrics        metricData
}

const (
	lifecycleImportBlocked = iota
	lifecycleImportPending
	lifecycleOther
	lifecycleCount
)

const (
	capabilityJoinParts = iota
	capabilityManualImportFile
	capabilityCount
)

const (
	decisionNoRepair = iota
	decisionJoinParts
	decisionManualImportFile
	decisionCount
)

var noRepairReasons = [...]contracts.NoRepairDecisionReason{
	contracts.NoRepairNeeded,
	contracts.NotAMultipartRelease,
	contracts.AmbiguousPartOrder,
	contracts.AmbiguousFileSelection,
	contracts.ContentNotSingleMovie,
	contracts.RawDiscUnsupported,
	contracts.MissingImportMetadata,
	contracts.InsufficientEvidence,
	contracts.UnsupportedRepair,
	contracts.UnsafeToRepair,
}

var plannerFailureKinds = [...]casestore.PlanningFailureKind{
	casestore.PlanningFailureUnavailable,
	casestore.PlanningFailureTimeout,
	casestore.PlanningFailureHTTP,
	casestore.PlanningFailureInvalidResult,
	casestore.PlanningFailureUnexpected,
}

type metricData struct {
	collectionFailed  bool
	lifecycleStates   [lifecycleCount]int
	capabilities      [capabilityCount]int
	decisions         [decisionCount]int
	noRepair          [len(noRepairReasons)]int
	plannerFailures   [len(plannerFailureKinds)]int
	plannerDuration   time.Duration
	oldestCompletedAt time.Time
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
	for _, assembly := range assemblies {
		report.observe(assembly)
	}
	runErrors := make([]error, 0, len(assemblies)+1)
	if collectionErr != nil {
		report.metrics.collectionFailed = true
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
	caseSuperseded
)

type caseResult struct {
	Outcome         caseOutcome
	Stored          bool
	Submitted       bool
	Assembly        casebuilder.Assembly
	Decision        contracts.RepairDecisionV2
	PlannerFailure  *casestore.PlanningFailure
	PlannerDuration time.Duration
}

func (report *Report) add(result caseResult) {
	if result.Stored {
		report.Stored++
	}
	if result.Submitted {
		report.Submitted++
		report.metrics.plannerDuration += result.PlannerDuration
	}
	if result.Outcome == caseDecided && result.Decision.Kind != "" {
		report.observeDecision(result.Decision)
	}
	if result.PlannerFailure != nil {
		report.observePlannerFailure(result.PlannerFailure.Kind)
	}
	switch result.Outcome {
	case caseDecided:
		report.Decided++
		report.PlannedCases = append(report.PlannedCases, casestore.PlannedCase{
			Assembly: result.Assembly, Decision: result.Decision,
		})
	case caseAlreadyDecided:
		report.AlreadyDecided++
		report.PlannedCases = append(report.PlannedCases, casestore.PlannedCase{
			Assembly: result.Assembly, Decision: result.Decision,
		})
	case caseDeferred:
		report.Deferred++
	case caseSuperseded:
		report.Superseded++
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
	result := caseResult{Stored: created, Assembly: assembly}
	observation := assembly.LocalSnapshot.Observation
	if controller.AllReplacementsSuperseded(
		observation.Movie,
		observation.ManualImports,
	) {
		result.Outcome = caseSuperseded
		return result, nil
	}
	caseID := assembly.Request.CaseID
	previous, found, err := runner.dependencies.Store.GetPlanningResult(caseID)
	if err != nil {
		result.Outcome = caseFailed
		return result, fmt.Errorf("read planning result: %w", err)
	}
	if found && previous.HasDecision() {
		planned, err := runner.loadPlannedCase(caseID)
		if err != nil {
			result.Outcome = caseFailed
			return result, err
		}
		result.Assembly = planned.Assembly
		result.Decision = planned.Decision
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
	startedAt := now
	decision, planErr := runner.dependencies.Planner.Plan(ctx, assembly.Request)
	completedAt := runner.dependencies.Clock.Now().UTC()
	if completedAt.IsZero() {
		result.Outcome = caseFailed
		return result, fmt.Errorf("clock returned a zero time")
	}
	if completedAt.After(startedAt) {
		result.PlannerDuration = completedAt.Sub(startedAt)
	}
	if planErr != nil {
		priorAttempts := uint64(0)
		if found {
			priorAttempts = previous.Attempts
		}
		retryAfter := completedAt.Add(runner.dependencies.Backoff.delay(priorAttempts))
		failure := runner.dependencies.ClassifyFailure(planErr)
		result.PlannerFailure = &failure
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
		planned, err := runner.loadPlannedCase(caseID)
		if err != nil {
			result.Outcome = caseFailed
			return result, err
		}
		result.Assembly = planned.Assembly
		result.Decision = planned.Decision
		result.Outcome = caseAlreadyDecided
		return result, nil
	}
	if !changed {
		result.Outcome = caseFailed
		return result, fmt.Errorf("result store did not record the planning decision")
	}
	result.Decision, err = planningDecision(caseID, stored)
	if err != nil {
		result.Outcome = caseFailed
		return result, err
	}
	result.Outcome = caseDecided
	return result, nil
}

func (runner *Runner) loadPlannedCase(caseID string) (casestore.PlannedCase, error) {
	planned, err := runner.dependencies.Store.GetPlannedCase(caseID)
	if err != nil {
		return casestore.PlannedCase{}, fmt.Errorf("load stored planned case: %w", err)
	}
	if planned.Decision.CaseID() != caseID {
		return casestore.PlannedCase{}, fmt.Errorf(
			"planning decision case ID does not match observed case %q",
			caseID,
		)
	}
	return planned, nil
}

func planningDecision(
	caseID string,
	result casestore.PlanningResult,
) (contracts.RepairDecisionV2, error) {
	decision, err := contracts.DecodeDecision(result.Decision)
	if err != nil {
		return contracts.RepairDecisionV2{}, fmt.Errorf("decode planning decision: %w", err)
	}
	if decision.CaseID() != caseID {
		return contracts.RepairDecisionV2{}, fmt.Errorf(
			"planning decision case ID does not match observed case %q",
			caseID,
		)
	}
	return decision, nil
}

func (report *Report) observe(assembly casebuilder.Assembly) {
	switch assembly.Request.Radarr.Failure.TrackedDownloadState {
	case "importBlocked":
		report.metrics.lifecycleStates[lifecycleImportBlocked]++
	case "importPending":
		report.metrics.lifecycleStates[lifecycleImportPending]++
	default:
		report.metrics.lifecycleStates[lifecycleOther]++
	}
	for _, capability := range assembly.Request.Capabilities {
		switch capability.Action {
		case contracts.CapabilityActionJoinParts:
			report.metrics.capabilities[capabilityJoinParts]++
		case contracts.CapabilityActionManualImportFile:
			report.metrics.capabilities[capabilityManualImportFile]++
		}
	}
	if completedAt := assembly.Request.Download.CompletedAt; completedAt != nil &&
		(report.metrics.oldestCompletedAt.IsZero() || completedAt.Before(report.metrics.oldestCompletedAt)) {
		report.metrics.oldestCompletedAt = completedAt.UTC()
	}
}

func (report *Report) observeDecision(decision contracts.RepairDecisionV2) {
	switch decision.Kind {
	case contracts.ActionNoRepair:
		report.metrics.decisions[decisionNoRepair]++
		if decision.NoRepair == nil {
			return
		}
		reason := decision.NoRepair.Reason
		for index, known := range noRepairReasons {
			if reason == known {
				report.metrics.noRepair[index]++
				return
			}
		}
	case contracts.ActionJoinParts:
		report.metrics.decisions[decisionJoinParts]++
	case contracts.ActionManualImportFile:
		report.metrics.decisions[decisionManualImportFile]++
	}
}

func (report *Report) observePlannerFailure(kind casestore.PlanningFailureKind) {
	for index, known := range plannerFailureKinds {
		if kind == known {
			report.metrics.plannerFailures[index]++
			return
		}
	}
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

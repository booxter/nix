package shadow

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/inspection"
	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
)

type CaseSource interface {
	InspectAll(context.Context) (inspection.Result, error)
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
		contracts.RepairDecisionV3,
		time.Time,
	) (casestore.PlanningResult, bool, error)
}

type FailureClassifier func(error) casestore.PlanningFailure

type Backoff planningrunner.Backoff

func (backoff Backoff) delay(priorAttempts uint64) time.Duration {
	return planningrunner.Backoff(backoff).Delay(priorAttempts)
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
	Rejected       int
	Rejections     []inspection.Rejection
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
	capabilityRemuxBluray
	capabilityRemuxDVD
	capabilityCount
)

const (
	decisionNoRepair = iota
	decisionJoinParts
	decisionManualImportFile
	decisionRemuxBluray
	decisionRemuxDVD
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
	planner      *planningrunner.Runner[
		casebuilder.Assembly,
		contracts.RepairDecisionV3,
		casestore.PlanningFailure,
	]
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
		planner, err := planningrunner.New(planningrunner.Dependencies[
			casebuilder.Assembly,
			contracts.RepairDecisionV3,
			casestore.PlanningFailure,
		]{
			Store: radarrPlanningStore{store: dependencies.Store},
			Plan: func(ctx context.Context, assembly casebuilder.Assembly) (
				contracts.RepairDecisionV3,
				error,
			) {
				return dependencies.Planner.Plan(ctx, assembly.Request)
			},
			Clock:          dependencies.Clock,
			CaseID:         func(assembly casebuilder.Assembly) string { return assembly.Request.CaseID },
			DecisionCaseID: func(decision contracts.RepairDecisionV3) string { return decision.CaseID() },
			Superseded: func(assembly casebuilder.Assembly) bool {
				observation := assembly.LocalSnapshot.Observation
				return controller.AllReplacementsSuperseded(
					observation.Movie,
					observation.ManualImports,
				)
			},
			ClassifyFailure: dependencies.ClassifyFailure,
			Backoff: planningrunner.Backoff{
				Initial: dependencies.Backoff.Initial,
				Maximum: dependencies.Backoff.Maximum,
			},
		})
		if err != nil {
			return nil, err
		}
		return &Runner{dependencies: dependencies, planner: planner}, nil
	}
}

func (runner *Runner) Run(ctx context.Context) (Report, error) {
	if runner == nil {
		return Report{}, fmt.Errorf("shadow runner is not configured")
	}
	if err := ctx.Err(); err != nil {
		return Report{}, err
	}

	collection, collectionErr := runner.dependencies.Cases.InspectAll(ctx)
	assemblies := collection.Assemblies
	report := Report{
		Observed:   len(assemblies),
		Rejected:   len(collection.Rejections),
		Rejections: append([]inspection.Rejection(nil), collection.Rejections...),
	}
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
	Decision        contracts.RepairDecisionV3
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
	shared, err := runner.planner.Process(ctx, assembly)
	return caseResult{
		Outcome:         sharedOutcome(shared.Outcome),
		Stored:          shared.Stored,
		Submitted:       shared.Submitted,
		Assembly:        shared.Planned.Case,
		Decision:        shared.Planned.Decision,
		PlannerFailure:  shared.Failure,
		PlannerDuration: shared.PlannerDuration,
	}, err
}

func sharedOutcome(outcome planningrunner.Outcome) caseOutcome {
	switch outcome {
	case planningrunner.Decided:
		return caseDecided
	case planningrunner.AlreadyDecided:
		return caseAlreadyDecided
	case planningrunner.Deferred:
		return caseDeferred
	case planningrunner.Superseded:
		return caseSuperseded
	default:
		return caseFailed
	}
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
		case contracts.CapabilityActionRemuxBluray:
			report.metrics.capabilities[capabilityRemuxBluray]++
		case contracts.CapabilityActionRemuxDVD:
			report.metrics.capabilities[capabilityRemuxDVD]++
		}
	}
	if completedAt := assembly.Request.Download.CompletedAt; completedAt != nil &&
		(report.metrics.oldestCompletedAt.IsZero() || completedAt.Before(report.metrics.oldestCompletedAt)) {
		report.metrics.oldestCompletedAt = completedAt.UTC()
	}
}

func (report *Report) observeDecision(decision contracts.RepairDecisionV3) {
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
	case contracts.ActionRemuxBluray:
		report.metrics.decisions[decisionRemuxBluray]++
	case contracts.ActionRemuxDVD:
		report.metrics.decisions[decisionRemuxDVD]++
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

type radarrPlanningStore struct {
	store ResultStore
}

func (store radarrPlanningStore) PutCase(assembly casebuilder.Assembly) (bool, error) {
	return store.store.PutAssembly(assembly)
}

func (store radarrPlanningStore) GetStatus(
	caseID string,
) (planningrunner.Status, bool, error) {
	result, found, err := store.store.GetPlanningResult(caseID)
	return planningStatus(result), found, err
}

func (store radarrPlanningStore) GetPlanned(
	caseID string,
) (planningrunner.Planned[casebuilder.Assembly, contracts.RepairDecisionV3], error) {
	planned, err := store.store.GetPlannedCase(caseID)
	if err != nil {
		return planningrunner.Planned[casebuilder.Assembly, contracts.RepairDecisionV3]{}, err
	}
	return planningrunner.Planned[casebuilder.Assembly, contracts.RepairDecisionV3]{
		Case: planned.Assembly, Decision: planned.Decision,
	}, nil
}

func (store radarrPlanningStore) PutFailure(
	caseID string,
	failure casestore.PlanningFailure,
	attemptedAt time.Time,
	retryAfter time.Time,
) (planningrunner.Status, bool, error) {
	result, changed, err := store.store.PutPlanningFailure(
		caseID, failure, attemptedAt, retryAfter,
	)
	return planningStatus(result), changed, err
}

func (store radarrPlanningStore) PutDecision(
	caseID string,
	decision contracts.RepairDecisionV3,
	attemptedAt time.Time,
) (planningrunner.Status, bool, error) {
	result, changed, err := store.store.PutPlanningDecision(caseID, decision, attemptedAt)
	return planningStatus(result), changed, err
}

func planningStatus(result casestore.PlanningResult) planningrunner.Status {
	return planningrunner.Status{
		Attempts: result.Attempts, RetryAfter: result.RetryAfter, Decided: result.HasDecision(),
	}
}

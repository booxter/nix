package executioncheck

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/inspection"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

type RejectionReason string

const (
	DecisionRejected      RejectionReason = "decision_rejected"
	StabilizationPending  RejectionReason = "stabilization_pending"
	CaseUnavailable       RejectionReason = "case_unavailable"
	CaseChanged           RejectionReason = "case_changed"
	AuthorizationChanged  RejectionReason = "authorization_changed"
	SupersededReplacement RejectionReason = "superseded_replacement"
	UnprovedReplacement   RejectionReason = "unproved_replacement"
	JoinExecutionPresent  RejectionReason = "join_execution_present"
)

type Rejection struct {
	Reason         RejectionReason
	DecisionReason string
	Stabilization  *StabilizationAssessment
}

type StabilizationAssessment struct {
	ObservedAt  time.Time
	CheckedAt   time.Time
	RequiredAge time.Duration
	ActualAge   time.Duration
}

type Authorization struct {
	Join         *decisionpolicy.AuthorizedJoin
	ManualImport *decisionpolicy.AuthorizedManualImport
}

type Result struct {
	Authorization Authorization
	Rejections    []Rejection
}

func (result Result) Accepted() bool {
	return len(result.Rejections) == 0 &&
		(result.Authorization.Join != nil) != (result.Authorization.ManualImport != nil)
}

type FreshCaseReader interface {
	Inspect(context.Context, inspection.Selection) (casebuilder.Assembly, error)
}

type JoinExecutionStateReader interface {
	InspectJoin(
		context.Context,
		string,
	) (workercontracts.InspectJoinResponseV1, error)
}

type Dependencies struct {
	Cases          FreshCaseReader
	Clock          controller.Clock
	JoinExecutions JoinExecutionStateReader
	Stabilization  time.Duration
}

type Checker struct {
	dependencies Dependencies
}

func New(dependencies Dependencies) (*Checker, error) {
	switch {
	case dependencies.Cases == nil:
		return nil, fmt.Errorf("fresh case reader is required")
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("execution check clock is required")
	case dependencies.JoinExecutions == nil:
		return nil, fmt.Errorf("join execution state reader is required")
	case dependencies.Stabilization <= 0:
		return nil, fmt.Errorf("stabilization interval must be positive")
	default:
		return &Checker{dependencies: dependencies}, nil
	}
}

func (checker *Checker) Check(
	ctx context.Context,
	stored casebuilder.Assembly,
	decision contracts.RepairDecisionV2,
) (Result, error) {
	if checker == nil {
		return Result{}, fmt.Errorf("execution checker is not configured")
	}
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}

	storedAuthorization, decisionReason, ok := authorize(stored, decision)
	if !ok {
		return rejectedDecision(DecisionRejected, decisionReason), nil
	}
	now := checker.dependencies.Clock.Now().UTC()
	if now.IsZero() {
		return Result{}, fmt.Errorf("clock returned a zero time")
	}
	observation := stored.LocalSnapshot.Observation
	if observation.Correlation.Radarr.TrackedDownloadState == "importPending" &&
		(now.Before(observation.ObservedAt) ||
			now.Sub(observation.ObservedAt) < checker.dependencies.Stabilization) {
		return Result{Rejections: []Rejection{{
			Reason: StabilizationPending,
			Stabilization: &StabilizationAssessment{
				ObservedAt:  observation.ObservedAt,
				CheckedAt:   now,
				RequiredAge: checker.dependencies.Stabilization,
				ActualAge:   now.Sub(observation.ObservedAt),
			},
		}}}, nil
	}

	queueID := observation.Correlation.Radarr.ID
	fresh, err := checker.dependencies.Cases.Inspect(
		ctx,
		inspection.Selection{QueueID: queueID},
	)
	if err != nil {
		var unavailable *inspection.CandidateUnavailableError
		if errors.As(err, &unavailable) {
			return rejected(CaseUnavailable), nil
		}
		return Result{}, fmt.Errorf("reinspect Radarr queue record %d: %w", queueID, err)
	}
	if fresh.Request.CaseID != stored.Request.CaseID {
		return rejected(CaseChanged), nil
	}
	freshAuthorization, decisionReason, ok := authorize(fresh, decision)
	if !ok {
		return rejectedDecision(AuthorizationChanged, decisionReason), nil
	}
	if reason, unsafe := replacementRejection(fresh, freshAuthorization); unsafe {
		return rejected(reason), nil
	}
	if !reflect.DeepEqual(freshAuthorization, storedAuthorization) {
		return rejected(AuthorizationChanged), nil
	}
	if !casebuilder.SameCaseState(stored, fresh) {
		return rejected(CaseChanged), nil
	}
	if freshAuthorization.Join != nil {
		executionID, identityErr := casestore.JoinExecutionID(*freshAuthorization.Join)
		if identityErr != nil {
			return Result{}, fmt.Errorf("derive join execution ID: %w", identityErr)
		}
		response, inspectErr := checker.dependencies.JoinExecutions.InspectJoin(ctx, executionID)
		if inspectErr != nil {
			return Result{}, fmt.Errorf("inspect join execution: %w", inspectErr)
		}
		if response.Failure != nil {
			return Result{}, fmt.Errorf(
				"inspect join execution: worker failed with reason %q",
				response.Failure.Reason,
			)
		}
		if response.Success == nil {
			return Result{}, fmt.Errorf("inspect join execution: worker returned no result")
		}
		if response.Success.State != workercontracts.InspectJoinAbsent {
			return rejected(JoinExecutionPresent), nil
		}
	}
	return Result{Authorization: freshAuthorization, Rejections: []Rejection{}}, nil
}

func authorize(
	assembly casebuilder.Assembly,
	decision contracts.RepairDecisionV2,
) (Authorization, string, bool) {
	switch decision.Kind {
	case contracts.ActionJoinParts:
		validation := decisionpolicy.ValidateJoin(assembly, decision)
		if validation.Accepted() {
			return Authorization{Join: validation.Authorized}, "", true
		}
		if len(validation.Rejections) != 0 {
			return Authorization{}, string(validation.Rejections[0].Reason), false
		}
	case contracts.ActionManualImportFile:
		validation := decisionpolicy.ValidateManualImport(assembly, decision)
		if validation.Accepted() {
			return Authorization{ManualImport: validation.Authorized}, "", true
		}
		if len(validation.Rejections) != 0 {
			return Authorization{}, string(validation.Rejections[0].Reason), false
		}
	}
	return Authorization{}, "", false
}

func rejected(reason RejectionReason) Result {
	return Result{Rejections: []Rejection{{Reason: reason}}}
}

func rejectedDecision(reason RejectionReason, decisionReason string) Result {
	return Result{Rejections: []Rejection{{
		Reason: reason, DecisionReason: decisionReason,
	}}}
}

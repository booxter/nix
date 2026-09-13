package joinrequest

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/joinstage"
	"github.com/booxter/nix-config/radarr-repair/worker/joinstate"
	"github.com/booxter/nix-config/radarr-repair/worker/mediaevidence"
)

type Store interface {
	Prepare(workercontracts.StageJoinRequestV1, time.Time) (joinstate.Execution, bool, error)
	MarkStaged(
		string,
		string,
		joinstate.StagedArtifact,
		time.Time,
	) (joinstate.Execution, bool, error)
	MarkStageFailed(
		string,
		workercontracts.StageJoinFailureReason,
		time.Time,
	) (joinstate.Execution, bool, error)
}

type Stager interface {
	StageOrRecover(context.Context, joinstate.Execution) (joinstage.Result, error)
}

type Dependencies struct {
	Store  Store
	Stager Stager
	Clock  controller.Clock
}

type Executor struct {
	dependencies Dependencies
	stageSlot    chan struct{}
}

var (
	_ Store  = (*joinstate.Store)(nil)
	_ Stager = (*joinstage.Executor)(nil)
)

func NewExecutor(dependencies Dependencies) (*Executor, error) {
	switch {
	case dependencies.Store == nil:
		return nil, fmt.Errorf("join state store is required")
	case dependencies.Stager == nil:
		return nil, fmt.Errorf("join stager is required")
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("clock is required")
	}
	return &Executor{
		dependencies: dependencies,
		stageSlot:    make(chan struct{}, 1),
	}, nil
}

func (executor *Executor) Execute(
	ctx context.Context,
	request workercontracts.StageJoinRequestV1,
) workercontracts.StageJoinResponseV1 {
	if executor == nil {
		return FailureResponse(request.RequestID, workercontracts.StageJoinInternalError)
	}
	select {
	case executor.stageSlot <- struct{}{}:
		defer func() { <-executor.stageSlot }()
	case <-ctx.Done():
		return FailureResponse(request.RequestID, workercontracts.StageJoinTimeout)
	}

	execution, _, err := executor.dependencies.Store.Prepare(
		request,
		executor.dependencies.Clock.Now().UTC(),
	)
	if err != nil {
		var conflict *joinstate.ConflictError
		if errors.As(err, &conflict) {
			return FailureResponse(
				request.RequestID,
				workercontracts.StageJoinExecutionConflict,
			)
		}
		return FailureResponse(request.RequestID, workercontracts.StageJoinInternalError)
	}

	switch execution.State {
	case joinstate.Staged:
		return storedSuccess(request.RequestID, execution)
	case joinstate.Failed:
		return storedFailure(request.RequestID, execution)
	case joinstate.Prepared:
		return executor.stage(ctx, request.RequestID, execution)
	case joinstate.Published, joinstate.Discarded:
		return FailureResponse(
			request.RequestID,
			workercontracts.StageJoinExecutionConflict,
		)
	default:
		return FailureResponse(request.RequestID, workercontracts.StageJoinInternalError)
	}
}

func (executor *Executor) stage(
	ctx context.Context,
	requestID string,
	execution joinstate.Execution,
) workercontracts.StageJoinResponseV1 {
	result, err := executor.dependencies.Stager.StageOrRecover(ctx, execution)
	if err != nil {
		reason := workercontracts.StageJoinInternalError
		var failure *joinstage.Failure
		if errors.As(err, &failure) {
			reason = failure.Reason
		}
		failed, _, storeErr := executor.dependencies.Store.MarkStageFailed(
			execution.ExecutionID,
			reason,
			executor.dependencies.Clock.Now().UTC(),
		)
		if storeErr != nil || failed.State != joinstate.Failed || failed.Failure == nil {
			return FailureResponse(requestID, workercontracts.StageJoinInternalError)
		}
		return storedFailure(requestID, failed)
	}

	staged, _, err := executor.dependencies.Store.MarkStaged(
		execution.ExecutionID,
		execution.ArtifactID,
		joinstate.StagedArtifact{
			Fingerprint: result.Fingerprint,
			SizeBytes:   result.SizeBytes,
			Evidence:    mediaevidence.FromProbe(result.Evidence),
		},
		executor.dependencies.Clock.Now().UTC(),
	)
	if err != nil || staged.State != joinstate.Staged || staged.Staged == nil {
		return FailureResponse(requestID, workercontracts.StageJoinInternalError)
	}
	return storedSuccess(requestID, staged)
}

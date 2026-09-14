package joininspect

import (
	"context"
	"fmt"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/joinstate"
)

type Store interface {
	Get(string) (joinstate.Execution, bool, error)
}

type Executor struct {
	store Store
}

var _ Store = (*joinstate.Store)(nil)

func NewExecutor(store Store) (*Executor, error) {
	if store == nil {
		return nil, fmt.Errorf("join state store is required")
	}
	return &Executor{store: store}, nil
}

func (executor *Executor) Inspect(
	ctx context.Context,
	request workercontracts.InspectJoinRequestV1,
) workercontracts.InspectJoinResponseV1 {
	if executor == nil || ctx == nil || ctx.Err() != nil {
		return failureResponse(request.RequestID)
	}
	execution, found, err := executor.store.Get(request.ExecutionID)
	if err != nil {
		return failureResponse(request.RequestID)
	}
	if !found {
		return successResponse(request.RequestID, workercontracts.InspectJoinAbsent)
	}
	state, ok := responseState(execution.State)
	if !ok {
		return failureResponse(request.RequestID)
	}
	return successResponse(request.RequestID, state)
}

func responseState(state joinstate.State) (workercontracts.InspectJoinState, bool) {
	switch state {
	case joinstate.Prepared:
		return workercontracts.InspectJoinPrepared, true
	case joinstate.Staged:
		return workercontracts.InspectJoinStaged, true
	case joinstate.Published:
		return workercontracts.InspectJoinPublished, true
	case joinstate.Discarded:
		return workercontracts.InspectJoinDiscarded, true
	case joinstate.Failed:
		return workercontracts.InspectJoinFailed, true
	default:
		return "", false
	}
}

func successResponse(
	requestID string,
	state workercontracts.InspectJoinState,
) workercontracts.InspectJoinResponseV1 {
	return workercontracts.InspectJoinResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.InspectJoinSuccessResponseV1{
			Operation:     workercontracts.InspectJoinV1,
			RequestID:     requestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			State:         state,
			Status:        workercontracts.Ok,
		},
	}
}

func failureResponse(requestID string) workercontracts.InspectJoinResponseV1 {
	return workercontracts.InspectJoinResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.InspectJoinFailureResponseV1{
			Operation:     workercontracts.InspectJoinV1,
			Reason:        workercontracts.InspectJoinInternal,
			RequestID:     requestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status:        workercontracts.Failed,
		},
	}
}

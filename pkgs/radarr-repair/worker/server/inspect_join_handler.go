package workerserver

import (
	"context"
	"fmt"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const inspectJoinPath = "/v1/join/inspect"

type InspectJoinExecutor interface {
	Inspect(
		context.Context,
		workercontracts.InspectJoinRequestV1,
	) workercontracts.InspectJoinResponseV1
}

type InspectJoinHandler = operationHandler[
	workercontracts.InspectJoinRequestV1,
	workercontracts.InspectJoinResponseV1,
]

func NewInspectJoinHandler(
	executor InspectJoinExecutor,
	timeout time.Duration,
) (*InspectJoinHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("join inspection executor is required")
	}
	return newOperationHandler(
		"join inspection", inspectJoinPath, workercontracts.MaxJoinRequestBytes, timeout, 1,
		workercontracts.DecodeInspectJoinRequest,
		executor.Inspect,
		workercontracts.EncodeInspectJoinResponse,
	)
}

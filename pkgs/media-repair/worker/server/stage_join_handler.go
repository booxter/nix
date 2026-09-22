package workerserver

import (
	"context"
	"fmt"
	"time"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

const stageJoinPath = "/v1/join/stage"

type StageJoinExecutor interface {
	Execute(
		context.Context,
		workercontracts.StageJoinRequestV1,
	) workercontracts.StageJoinResponseV1
}

type StageJoinHandler = operationHandler[
	workercontracts.StageJoinRequestV1,
	workercontracts.StageJoinResponseV1,
]

func NewStageJoinHandler(
	executor StageJoinExecutor,
	timeout time.Duration,
) (*StageJoinHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("stage join executor is required")
	}
	return newOperationHandler(
		"join staging", stageJoinPath, workercontracts.MaxJoinRequestBytes, timeout, 1,
		workercontracts.DecodeStageJoinRequest,
		executor.Execute,
		workercontracts.EncodeStageJoinResponse,
	)
}

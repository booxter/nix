package workerserver

import (
	"context"
	"fmt"
	"time"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

const blurayPublishPath = "/v1/bluray/publish"

type BlurayPublishExecutor interface {
	Execute(context.Context, workercontracts.BlurayPublishRequestV1) workercontracts.BlurayPublishResponseV1
}

type BlurayPublishHandler = operationHandler[
	workercontracts.BlurayPublishRequestV1,
	workercontracts.BlurayPublishResponseV1,
]

func NewBlurayPublishHandler(
	executor BlurayPublishExecutor,
	timeout time.Duration,
) (*BlurayPublishHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("Blu-ray publish executor is required")
	}
	return newOperationHandler(
		"Blu-ray publish", blurayPublishPath,
		workercontracts.MaxBlurayPublishRequestBytes, timeout, 1,
		workercontracts.DecodeBlurayPublishRequest,
		executor.Execute,
		workercontracts.EncodeBlurayPublishResponse,
	)
}

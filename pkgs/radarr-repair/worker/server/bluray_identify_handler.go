package workerserver

import (
	"context"
	"fmt"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const blurayIdentifyPath = "/v1/bluray/identify"

type BlurayIdentifyExecutor interface {
	Execute(context.Context, workercontracts.BlurayIdentifyRequestV1) workercontracts.BlurayIdentifyResponseV1
}

type BlurayIdentifyHandler = operationHandler[
	workercontracts.BlurayIdentifyRequestV1,
	workercontracts.BlurayIdentifyResponseV1,
]

func NewBlurayIdentifyHandler(
	executor BlurayIdentifyExecutor,
	timeout time.Duration,
	maxConcurrent int,
) (*BlurayIdentifyHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("Blu-ray identification executor is required")
	}
	return newOperationHandler(
		"Blu-ray identification", blurayIdentifyPath,
		workercontracts.MaxBlurayIdentifyRequestBytes, timeout, maxConcurrent,
		workercontracts.DecodeBlurayIdentifyRequest,
		executor.Execute,
		workercontracts.EncodeBlurayIdentifyResponse,
	)
}

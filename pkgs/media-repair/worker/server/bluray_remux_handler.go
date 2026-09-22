package workerserver

import (
	"context"
	"fmt"
	"time"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

const blurayRemuxPath = "/v1/bluray/remux"

type BlurayRemuxExecutor interface {
	Execute(context.Context, workercontracts.BlurayRemuxRequestV1) workercontracts.BlurayRemuxResponseV1
}

type BlurayRemuxHandler = operationHandler[
	workercontracts.BlurayRemuxRequestV1,
	workercontracts.BlurayRemuxResponseV1,
]

func NewBlurayRemuxHandler(
	executor BlurayRemuxExecutor,
	timeout time.Duration,
) (*BlurayRemuxHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("Blu-ray remux executor is required")
	}
	return newOperationHandler(
		"Blu-ray remux", blurayRemuxPath,
		workercontracts.MaxBlurayRemuxRequestBytes, timeout, 1,
		workercontracts.DecodeBlurayRemuxRequest,
		executor.Execute,
		workercontracts.EncodeBlurayRemuxResponse,
	)
}

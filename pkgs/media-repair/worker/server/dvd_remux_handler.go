package workerserver

import (
	"context"
	"fmt"
	"time"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

const dvdRemuxPath = "/v1/dvd/remux"

type DVDRemuxExecutor interface {
	Execute(context.Context, workercontracts.DVDRemuxRequestV1) workercontracts.DVDRemuxResponseV1
}

type DVDRemuxHandler = operationHandler[
	workercontracts.DVDRemuxRequestV1,
	workercontracts.DVDRemuxResponseV1,
]

func NewDVDRemuxHandler(executor DVDRemuxExecutor, timeout time.Duration) (*DVDRemuxHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("DVD remux executor is required")
	}
	return newOperationHandler(
		"DVD remux", dvdRemuxPath, workercontracts.MaxDVDRemuxRequestBytes, timeout, 1,
		workercontracts.DecodeDVDRemuxRequest, executor.Execute,
		workercontracts.EncodeDVDRemuxResponse,
	)
}

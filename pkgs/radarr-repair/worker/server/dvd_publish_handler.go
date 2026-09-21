package workerserver

import (
	"context"
	"fmt"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const dvdPublishPath = "/v1/dvd/publish"

type DVDPublishExecutor interface {
	Execute(context.Context, workercontracts.DVDPublishRequestV1) workercontracts.DVDPublishResponseV1
}

type DVDPublishHandler = operationHandler[
	workercontracts.DVDPublishRequestV1,
	workercontracts.DVDPublishResponseV1,
]

func NewDVDPublishHandler(executor DVDPublishExecutor, timeout time.Duration) (*DVDPublishHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("DVD publish executor is required")
	}
	return newOperationHandler(
		"DVD publish", dvdPublishPath, workercontracts.MaxDVDPublishRequestBytes, timeout, 1,
		workercontracts.DecodeDVDPublishRequest, executor.Execute,
		workercontracts.EncodeDVDPublishResponse,
	)
}

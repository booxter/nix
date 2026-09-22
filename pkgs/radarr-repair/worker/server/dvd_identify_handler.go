package workerserver

import (
	"context"
	"fmt"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const dvdIdentifyPath = "/v1/dvd/identify"

type DVDIdentifyExecutor interface {
	Execute(context.Context, workercontracts.DVDIdentifyRequestV1) workercontracts.DVDIdentifyResponseV1
}

type DVDIdentifyHandler = operationHandler[
	workercontracts.DVDIdentifyRequestV1,
	workercontracts.DVDIdentifyResponseV1,
]

func NewDVDIdentifyHandler(
	executor DVDIdentifyExecutor, timeout time.Duration, maxConcurrent int,
) (*DVDIdentifyHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("DVD identification executor is required")
	}
	return newOperationHandler(
		"DVD identification", dvdIdentifyPath,
		workercontracts.MaxDVDIdentifyRequestBytes, timeout, maxConcurrent,
		workercontracts.DecodeDVDIdentifyRequest,
		executor.Execute,
		workercontracts.EncodeDVDIdentifyResponse,
	)
}

package workerserver

import (
	"context"
	"fmt"
	"net/http"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const dvdIdentifyPath = "/v1/dvd/identify"

type DVDIdentifyExecutor interface {
	Execute(context.Context, workercontracts.DVDIdentifyRequestV1) workercontracts.DVDIdentifyResponseV1
}

type DVDIdentifyHandler struct {
	executor DVDIdentifyExecutor
	settings operationSettings
}

func NewDVDIdentifyHandler(
	executor DVDIdentifyExecutor, timeout time.Duration, maxConcurrent int,
) (*DVDIdentifyHandler, error) {
	if executor == nil || timeout <= 0 || maxConcurrent <= 0 {
		return nil, fmt.Errorf("DVD identification handler needs an executor, timeout, and concurrency limit")
	}
	return &DVDIdentifyHandler{
		executor: executor,
		settings: operationSettings{
			path: dvdIdentifyPath, maxRequestBytes: workercontracts.MaxDVDIdentifyRequestBytes,
			timeout: timeout, slots: make(chan struct{}, maxConcurrent),
		},
	}, nil
}

func (handler *DVDIdentifyHandler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	serveOperation(
		writer, request, handler.settings,
		workercontracts.DecodeDVDIdentifyRequest,
		handler.executor.Execute,
		workercontracts.EncodeDVDIdentifyResponse,
	)
}

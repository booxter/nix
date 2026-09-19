package workerserver

import (
	"context"
	"fmt"
	"net/http"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const dvdPublishPath = "/v1/dvd/publish"

type DVDPublishExecutor interface {
	Execute(context.Context, workercontracts.DVDPublishRequestV1) workercontracts.DVDPublishResponseV1
}

type DVDPublishHandler struct {
	executor DVDPublishExecutor
	settings operationSettings
}

func NewDVDPublishHandler(executor DVDPublishExecutor, timeout time.Duration) (*DVDPublishHandler, error) {
	if executor == nil || timeout <= 0 {
		return nil, fmt.Errorf("DVD publish handler needs an executor and timeout")
	}
	return &DVDPublishHandler{executor: executor, settings: operationSettings{
		path: dvdPublishPath, maxRequestBytes: workercontracts.MaxDVDPublishRequestBytes,
		timeout: timeout, slots: make(chan struct{}, 1),
	}}, nil
}

func (handler *DVDPublishHandler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	serveOperation(writer, request, handler.settings,
		workercontracts.DecodeDVDPublishRequest, handler.executor.Execute,
		workercontracts.EncodeDVDPublishResponse)
}

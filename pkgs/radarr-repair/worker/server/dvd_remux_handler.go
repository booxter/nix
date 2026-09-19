package workerserver

import (
	"context"
	"fmt"
	"net/http"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const dvdRemuxPath = "/v1/dvd/remux"

type DVDRemuxExecutor interface {
	Execute(context.Context, workercontracts.DVDRemuxRequestV1) workercontracts.DVDRemuxResponseV1
}

type DVDRemuxHandler struct {
	executor DVDRemuxExecutor
	settings operationSettings
}

func NewDVDRemuxHandler(executor DVDRemuxExecutor, timeout time.Duration) (*DVDRemuxHandler, error) {
	if executor == nil || timeout <= 0 {
		return nil, fmt.Errorf("DVD remux handler needs an executor and timeout")
	}
	return &DVDRemuxHandler{executor: executor, settings: operationSettings{
		path: dvdRemuxPath, maxRequestBytes: workercontracts.MaxDVDRemuxRequestBytes,
		timeout: timeout, slots: make(chan struct{}, 1),
	}}, nil
}

func (handler *DVDRemuxHandler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	serveOperation(writer, request, handler.settings,
		workercontracts.DecodeDVDRemuxRequest, handler.executor.Execute,
		workercontracts.EncodeDVDRemuxResponse)
}

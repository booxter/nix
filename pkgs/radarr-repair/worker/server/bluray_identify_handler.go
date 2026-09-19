package workerserver

import (
	"context"
	"fmt"
	"net/http"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const blurayIdentifyPath = "/v1/bluray/identify"

type BlurayIdentifyExecutor interface {
	Execute(context.Context, workercontracts.BlurayIdentifyRequestV1) workercontracts.BlurayIdentifyResponseV1
}

type BlurayIdentifyHandler struct {
	executor BlurayIdentifyExecutor
	settings operationSettings
}

func NewBlurayIdentifyHandler(
	executor BlurayIdentifyExecutor,
	timeout time.Duration,
	maxConcurrent int,
) (*BlurayIdentifyHandler, error) {
	if executor == nil || timeout <= 0 || maxConcurrent <= 0 {
		return nil, fmt.Errorf("Blu-ray identification handler needs an executor, timeout, and concurrency limit")
	}
	return &BlurayIdentifyHandler{
		executor: executor,
		settings: operationSettings{
			path: blurayIdentifyPath, maxRequestBytes: workercontracts.MaxBlurayIdentifyRequestBytes,
			timeout: timeout, slots: make(chan struct{}, maxConcurrent),
		},
	}, nil
}

func (handler *BlurayIdentifyHandler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	serveOperation(
		writer, request, handler.settings,
		workercontracts.DecodeBlurayIdentifyRequest,
		handler.executor.Execute,
		workercontracts.EncodeBlurayIdentifyResponse,
	)
}

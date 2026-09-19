package workerserver

import (
	"context"
	"fmt"
	"net/http"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const blurayPublishPath = "/v1/bluray/publish"

type BlurayPublishExecutor interface {
	Execute(context.Context, workercontracts.BlurayPublishRequestV1) workercontracts.BlurayPublishResponseV1
}

type BlurayPublishHandler struct {
	executor BlurayPublishExecutor
	settings operationSettings
}

func NewBlurayPublishHandler(
	executor BlurayPublishExecutor,
	timeout time.Duration,
) (*BlurayPublishHandler, error) {
	if executor == nil || timeout <= 0 {
		return nil, fmt.Errorf("Blu-ray publish handler needs an executor and timeout")
	}
	return &BlurayPublishHandler{
		executor: executor,
		settings: operationSettings{
			path:            blurayPublishPath,
			maxRequestBytes: workercontracts.MaxBlurayPublishRequestBytes,
			timeout:         timeout,
			slots:           make(chan struct{}, 1),
		},
	}, nil
}

func (handler *BlurayPublishHandler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	serveOperation(
		writer, request, handler.settings,
		workercontracts.DecodeBlurayPublishRequest,
		handler.executor.Execute,
		workercontracts.EncodeBlurayPublishResponse,
	)
}

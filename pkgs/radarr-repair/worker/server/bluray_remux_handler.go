package workerserver

import (
	"context"
	"fmt"
	"net/http"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const blurayRemuxPath = "/v1/bluray/remux"

type BlurayRemuxExecutor interface {
	Execute(context.Context, workercontracts.BlurayRemuxRequestV1) workercontracts.BlurayRemuxResponseV1
}

type BlurayRemuxHandler struct {
	executor BlurayRemuxExecutor
	settings operationSettings
}

func NewBlurayRemuxHandler(
	executor BlurayRemuxExecutor,
	timeout time.Duration,
) (*BlurayRemuxHandler, error) {
	if executor == nil || timeout <= 0 {
		return nil, fmt.Errorf("Blu-ray remux handler needs an executor and timeout")
	}
	return &BlurayRemuxHandler{
		executor: executor,
		settings: operationSettings{
			path:            blurayRemuxPath,
			maxRequestBytes: workercontracts.MaxBlurayRemuxRequestBytes,
			timeout:         timeout,
			slots:           make(chan struct{}, 1),
		},
	}, nil
}

func (handler *BlurayRemuxHandler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	serveOperation(
		writer, request, handler.settings,
		workercontracts.DecodeBlurayRemuxRequest,
		handler.executor.Execute,
		workercontracts.EncodeBlurayRemuxResponse,
	)
}

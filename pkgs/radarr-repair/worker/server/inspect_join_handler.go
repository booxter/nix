package workerserver

import (
	"context"
	"fmt"
	"net/http"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const inspectJoinPath = "/v1/join/inspect"

type InspectJoinExecutor interface {
	Inspect(
		context.Context,
		workercontracts.InspectJoinRequestV1,
	) workercontracts.InspectJoinResponseV1
}

type InspectJoinHandler struct {
	executor InspectJoinExecutor
	settings operationSettings
}

func NewInspectJoinHandler(
	executor InspectJoinExecutor,
	timeout time.Duration,
) (*InspectJoinHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("join inspection executor is required")
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("join inspection request timeout must be positive")
	}
	return &InspectJoinHandler{
		executor: executor,
		settings: operationSettings{
			path:            inspectJoinPath,
			maxRequestBytes: workercontracts.MaxJoinRequestBytes,
			timeout:         timeout,
			slots:           make(chan struct{}, 1),
		},
	}, nil
}

func (handler *InspectJoinHandler) ServeHTTP(
	writer http.ResponseWriter,
	request *http.Request,
) {
	serveOperation(
		writer,
		request,
		handler.settings,
		workercontracts.DecodeInspectJoinRequest,
		handler.executor.Inspect,
		workercontracts.EncodeInspectJoinResponse,
	)
}

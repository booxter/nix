package workerserver

import (
	"context"
	"fmt"
	"net/http"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const stageJoinPath = "/v1/join/stage"

type StageJoinExecutor interface {
	Execute(
		context.Context,
		workercontracts.StageJoinRequestV1,
	) workercontracts.StageJoinResponseV1
}

type StageJoinHandler struct {
	executor StageJoinExecutor
	settings operationSettings
}

func NewStageJoinHandler(
	executor StageJoinExecutor,
	timeout time.Duration,
) (*StageJoinHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("stage join executor is required")
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("stage join request timeout must be positive")
	}
	return &StageJoinHandler{
		executor: executor,
		settings: operationSettings{
			path:            stageJoinPath,
			maxRequestBytes: workercontracts.MaxJoinRequestBytes,
			timeout:         timeout,
			slots:           make(chan struct{}, 1),
		},
	}, nil
}

func (handler *StageJoinHandler) ServeHTTP(
	writer http.ResponseWriter,
	request *http.Request,
) {
	serveOperation(
		writer,
		request,
		handler.settings,
		workercontracts.DecodeStageJoinRequest,
		handler.executor.Execute,
		workercontracts.EncodeStageJoinResponse,
	)
}

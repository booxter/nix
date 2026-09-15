package workerserver

import (
	"context"
	"fmt"
	"net/http"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const (
	publishPath = "/v1/join/publish"
	discardPath = "/v1/join/discard"
)

type PublishExecutor interface {
	Publish(
		context.Context,
		workercontracts.PublishRequestV1,
	) workercontracts.PublishResponseV1
}

type DiscardExecutor interface {
	Discard(
		context.Context,
		workercontracts.DiscardRequestV1,
	) workercontracts.DiscardResponseV1
}

type PublishHandler struct {
	executor PublishExecutor
	settings operationSettings
}

func NewPublishHandler(
	executor PublishExecutor,
	timeout time.Duration,
) (*PublishHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("join publish executor is required")
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("join publish request timeout must be positive")
	}
	return &PublishHandler{
		executor: executor,
		settings: operationSettings{
			path:            publishPath,
			maxRequestBytes: workercontracts.MaxJoinRequestBytes,
			timeout:         timeout,
			slots:           make(chan struct{}, 1),
		},
	}, nil
}

func (handler *PublishHandler) ServeHTTP(
	writer http.ResponseWriter,
	request *http.Request,
) {
	serveOperation(
		writer,
		request,
		handler.settings,
		workercontracts.DecodePublishRequest,
		handler.executor.Publish,
		workercontracts.EncodePublishResponse,
	)
}

type DiscardHandler struct {
	executor DiscardExecutor
	settings operationSettings
}

func NewDiscardHandler(
	executor DiscardExecutor,
	timeout time.Duration,
) (*DiscardHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("join discard executor is required")
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("join discard request timeout must be positive")
	}
	return &DiscardHandler{
		executor: executor,
		settings: operationSettings{
			path:            discardPath,
			maxRequestBytes: workercontracts.MaxJoinRequestBytes,
			timeout:         timeout,
			slots:           make(chan struct{}, 1),
		},
	}, nil
}

func (handler *DiscardHandler) ServeHTTP(
	writer http.ResponseWriter,
	request *http.Request,
) {
	serveOperation(
		writer,
		request,
		handler.settings,
		workercontracts.DecodeDiscardRequest,
		handler.executor.Discard,
		workercontracts.EncodeDiscardResponse,
	)
}

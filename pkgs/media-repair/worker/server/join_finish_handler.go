package workerserver

import (
	"context"
	"fmt"
	"time"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
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

type PublishHandler = operationHandler[
	workercontracts.PublishRequestV1,
	workercontracts.PublishResponseV1,
]

func NewPublishHandler(
	executor PublishExecutor,
	timeout time.Duration,
) (*PublishHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("join publish executor is required")
	}
	return newOperationHandler(
		"join publish", publishPath, workercontracts.MaxJoinRequestBytes, timeout, 1,
		workercontracts.DecodePublishRequest,
		executor.Publish,
		workercontracts.EncodePublishResponse,
	)
}

type DiscardHandler = operationHandler[
	workercontracts.DiscardRequestV1,
	workercontracts.DiscardResponseV1,
]

func NewDiscardHandler(
	executor DiscardExecutor,
	timeout time.Duration,
) (*DiscardHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("join discard executor is required")
	}
	return newOperationHandler(
		"join discard", discardPath, workercontracts.MaxJoinRequestBytes, timeout, 1,
		workercontracts.DecodeDiscardRequest,
		executor.Discard,
		workercontracts.EncodeDiscardResponse,
	)
}

package workerserver

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

const materializeTarPath = "/v1/materialize/tar-audio"
const materializeTarVideoPath = "/v1/materialize/tar-video"
const materializeDirectoryPath = "/v1/materialize/directory-audio"

type MaterializeExecutor interface {
	Execute(context.Context, materialize.Request) materialize.Response
}

func NewVideoMaterializeHandler(
	executor MaterializeExecutor,
	timeout time.Duration,
	maxConcurrent int,
) (*MaterializeHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("video materialization executor is required")
	}
	return newOperationHandler(
		"materialize tar video",
		materializeTarVideoPath,
		materialize.MaxRequestBytes,
		timeout,
		maxConcurrent,
		materialize.DecodeRequest,
		executor.Execute,
		materialize.EncodeResponse,
	)
}

type MaterializeHandler = operationHandler[materialize.Request, materialize.Response]

type DirectoryMaterializeExecutor interface {
	ExecuteDirectory(context.Context, materialize.Request) materialize.Response
}

func NewMaterializeHandler(
	executor MaterializeExecutor,
	timeout time.Duration,
	maxConcurrent int,
) (*MaterializeHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("materialization executor is required")
	}
	return newOperationHandler(
		"materialize tar audio",
		materializeTarPath,
		materialize.MaxRequestBytes,
		timeout,
		maxConcurrent,
		materialize.DecodeRequest,
		executor.Execute,
		materialize.EncodeResponse,
	)
}

func NewDirectoryMaterializeHandler(
	executor DirectoryMaterializeExecutor,
	timeout time.Duration,
	maxConcurrent int,
) (*MaterializeHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("directory materialization executor is required")
	}
	return newOperationHandler(
		"materialize directory audio",
		materializeDirectoryPath,
		materialize.MaxRequestBytes,
		timeout,
		maxConcurrent,
		materialize.DecodeRequest,
		executor.ExecuteDirectory,
		materialize.EncodeResponse,
	)
}

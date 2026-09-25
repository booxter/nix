package workerserver

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

const materializeTarPath = "/v1/materialize/tar-audio"
const materializeTarVideoPath = "/v1/materialize/tar-video"
const materializeRARPath = "/v1/materialize/rar-audio"
const materializeRARVideoPath = "/v1/materialize/rar-video"
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

type RARMaterializeExecutor interface {
	ExecuteRAR(context.Context, materialize.Request) materialize.Response
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

func NewRARMaterializeHandler(
	executor RARMaterializeExecutor,
	timeout time.Duration,
	maxConcurrent int,
) (*MaterializeHandler, error) {
	return newRARMaterializeHandler(
		executor, "materialize RAR audio", materializeRARPath, timeout, maxConcurrent,
	)
}

func NewRARVideoMaterializeHandler(
	executor RARMaterializeExecutor,
	timeout time.Duration,
	maxConcurrent int,
) (*MaterializeHandler, error) {
	return newRARMaterializeHandler(
		executor, "materialize RAR video", materializeRARVideoPath, timeout, maxConcurrent,
	)
}

func newRARMaterializeHandler(
	executor RARMaterializeExecutor,
	name string,
	path string,
	timeout time.Duration,
	maxConcurrent int,
) (*MaterializeHandler, error) {
	if executor == nil {
		return nil, fmt.Errorf("RAR materialization executor is required")
	}
	return newOperationHandler(
		name, path, materialize.MaxRequestBytes, timeout, maxConcurrent,
		materialize.DecodeRequest, executor.ExecuteRAR, materialize.EncodeResponse,
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

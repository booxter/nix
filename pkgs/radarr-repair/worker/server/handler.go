package workerserver

import (
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const probePath = "/v1/probe"

type ProbeExecutor interface {
	Execute(context.Context, workercontracts.ProbeRequestV1) workercontracts.ProbeResponseV1
}

type Handler = operationHandler[workercontracts.ProbeRequestV1, workercontracts.ProbeResponseV1]

type operationHandler[Request, Response any] struct {
	name     string
	settings operationSettings
	decode   func([]byte) (Request, error)
	execute  func(context.Context, Request) Response
	encode   func(Response) ([]byte, error)
}

func NewHandler(
	executor ProbeExecutor,
	timeout time.Duration,
	maxConcurrent int,
) (*Handler, error) {
	if executor == nil {
		return nil, fmt.Errorf("probe executor is required")
	}
	return newOperationHandler(
		"probe",
		probePath,
		workercontracts.MaxProbeRequestBytes,
		timeout,
		maxConcurrent,
		workercontracts.DecodeProbeRequest,
		executor.Execute,
		workercontracts.EncodeProbeResponse,
	)
}

func newOperationHandler[Request, Response any](
	name string,
	path string,
	maxRequestBytes int64,
	timeout time.Duration,
	maxConcurrent int,
	decode func([]byte) (Request, error),
	execute func(context.Context, Request) Response,
	encode func(Response) ([]byte, error),
) (*operationHandler[Request, Response], error) {
	if name == "" || path == "" || maxRequestBytes <= 0 || timeout <= 0 || maxConcurrent <= 0 ||
		decode == nil || execute == nil || encode == nil {
		return nil, fmt.Errorf("%s operation boundary is incomplete", name)
	}
	return &operationHandler[Request, Response]{
		name: name,
		settings: operationSettings{
			path: path, maxRequestBytes: maxRequestBytes,
			timeout: timeout, slots: make(chan struct{}, maxConcurrent),
		},
		decode: decode, execute: execute, encode: encode,
	}, nil
}

func (handler *operationHandler[Request, Response]) OperationPath() string {
	if handler == nil {
		return ""
	}
	return handler.settings.path
}

func (handler *operationHandler[Request, Response]) ServeHTTP(
	writer http.ResponseWriter,
	request *http.Request,
) {
	serveOperation(
		writer,
		request,
		handler.settings,
		handler.decode,
		handler.execute,
		handler.encode,
	)
}

type operationSettings struct {
	path            string
	maxRequestBytes int64
	timeout         time.Duration
	slots           chan struct{}
}

func serveOperation[Request, Response any](
	writer http.ResponseWriter,
	httpRequest *http.Request,
	settings operationSettings,
	decode func([]byte) (Request, error),
	execute func(context.Context, Request) Response,
	encode func(Response) ([]byte, error),
) {
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	if httpRequest.URL.Path != settings.path {
		writer.WriteHeader(http.StatusNotFound)
		return
	}
	if httpRequest.Method != http.MethodPost {
		writer.Header().Set("Allow", http.MethodPost)
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	mediaType, _, err := mime.ParseMediaType(httpRequest.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		writer.WriteHeader(http.StatusUnsupportedMediaType)
		return
	}

	body := http.MaxBytesReader(writer, httpRequest.Body, settings.maxRequestBytes)
	defer body.Close()
	data, err := io.ReadAll(body)
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writer.WriteHeader(http.StatusRequestEntityTooLarge)
		} else {
			writer.WriteHeader(http.StatusBadRequest)
		}
		return
	}
	operationRequest, err := decode(data)
	if err != nil {
		writer.WriteHeader(http.StatusBadRequest)
		return
	}

	select {
	case settings.slots <- struct{}{}:
		defer func() { <-settings.slots }()
	default:
		writer.WriteHeader(http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithTimeout(httpRequest.Context(), settings.timeout)
	defer cancel()
	response := execute(ctx, operationRequest)
	encoded, err := encode(response)
	if err != nil {
		writer.WriteHeader(http.StatusInternalServerError)
		return
	}

	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write(encoded)
}

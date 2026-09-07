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

type Handler struct {
	executor ProbeExecutor
	timeout  time.Duration
	slots    chan struct{}
}

func NewHandler(
	executor ProbeExecutor,
	timeout time.Duration,
	maxConcurrent int,
) (*Handler, error) {
	if executor == nil {
		return nil, fmt.Errorf("probe executor is required")
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("probe request timeout must be positive")
	}
	if maxConcurrent <= 0 {
		return nil, fmt.Errorf("probe concurrency limit must be positive")
	}
	return &Handler{
		executor: executor,
		timeout:  timeout,
		slots:    make(chan struct{}, maxConcurrent),
	}, nil
}

func (handler *Handler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	if request.URL.Path != probePath {
		writer.WriteHeader(http.StatusNotFound)
		return
	}
	if request.Method != http.MethodPost {
		writer.Header().Set("Allow", http.MethodPost)
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	mediaType, _, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		writer.WriteHeader(http.StatusUnsupportedMediaType)
		return
	}

	body := http.MaxBytesReader(writer, request.Body, workercontracts.MaxProbeRequestBytes)
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
	probeRequest, err := workercontracts.DecodeProbeRequest(data)
	if err != nil {
		writer.WriteHeader(http.StatusBadRequest)
		return
	}

	select {
	case handler.slots <- struct{}{}:
		defer func() { <-handler.slots }()
	default:
		writer.WriteHeader(http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithTimeout(request.Context(), handler.timeout)
	defer cancel()
	response := handler.executor.Execute(ctx, probeRequest)
	encoded, err := workercontracts.EncodeProbeResponse(response)
	if err != nil {
		writer.WriteHeader(http.StatusInternalServerError)
		return
	}

	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write(encoded)
}

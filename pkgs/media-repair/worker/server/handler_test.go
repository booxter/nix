package workerserver

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	workerprobe "github.com/booxter/nix-config/media-repair/worker/probe"
)

func TestHandlerServesTypedProbeResponse(t *testing.T) {
	t.Parallel()

	executor := &fakeExecutor{execute: func(
		_ context.Context,
		request workercontracts.ProbeRequestV1,
	) workercontracts.ProbeResponseV1 {
		return workerprobe.FailureResponse(request.RequestID, workercontracts.FingerprintMismatch)
	}}
	handler := testHandler(t, executor, time.Second, 1)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, validRequest(t))

	if recorder.Code != http.StatusOK ||
		recorder.Header().Get("Content-Type") != "application/json" ||
		recorder.Header().Get("Cache-Control") != "no-store" ||
		recorder.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("response status = %d, headers = %#v", recorder.Code, recorder.Header())
	}
	response, err := workercontracts.DecodeProbeResponse(recorder.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if response.RequestID() != "request:01" || response.Failure == nil ||
		response.Failure.Reason != workercontracts.FingerprintMismatch {
		t.Fatalf("response = %#v", response)
	}
}

func TestHandlerRejectsInvalidHTTPRequests(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		method      string
		path        string
		contentType string
		wantStatus  int
	}{
		{
			name: "unknown path", method: http.MethodPost, path: "/other",
			contentType: "application/json", wantStatus: http.StatusNotFound,
		},
		{
			name: "wrong method", method: http.MethodGet, path: probePath,
			contentType: "application/json", wantStatus: http.StatusMethodNotAllowed,
		},
		{
			name: "missing content type", method: http.MethodPost, path: probePath,
			wantStatus: http.StatusUnsupportedMediaType,
		},
		{
			name: "wrong content type", method: http.MethodPost, path: probePath,
			contentType: "text/plain", wantStatus: http.StatusUnsupportedMediaType,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			executor := &fakeExecutor{}
			handler := testHandler(t, executor, time.Second, 1)
			request := httptest.NewRequest(test.method, test.path, strings.NewReader("{}"))
			if test.contentType != "" {
				request.Header.Set("Content-Type", test.contentType)
			}
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)
			if recorder.Code != test.wantStatus || recorder.Body.Len() != 0 || executor.calls != 0 {
				t.Fatalf(
					"status = %d, body = %q, executor calls = %d",
					recorder.Code,
					recorder.Body.String(),
					executor.calls,
				)
			}
			if test.wantStatus == http.StatusMethodNotAllowed &&
				recorder.Header().Get("Allow") != http.MethodPost {
				t.Fatalf("Allow = %q", recorder.Header().Get("Allow"))
			}
		})
	}
}

func TestHandlerRejectsMalformedAndOversizedBodies(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		body       string
		wantStatus int
	}{
		{name: "malformed", body: "{", wantStatus: http.StatusBadRequest},
		{
			name: "oversized", body: strings.Repeat("x", workercontracts.MaxProbeRequestBytes+1),
			wantStatus: http.StatusRequestEntityTooLarge,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			executor := &fakeExecutor{}
			handler := testHandler(t, executor, time.Second, 1)
			request := httptest.NewRequest(http.MethodPost, probePath, strings.NewReader(test.body))
			request.Header.Set("Content-Type", "application/json")
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)
			if recorder.Code != test.wantStatus || recorder.Body.Len() != 0 || executor.calls != 0 {
				t.Fatalf(
					"status = %d, body = %q, executor calls = %d",
					recorder.Code,
					recorder.Body.String(),
					executor.calls,
				)
			}
		})
	}
}

func TestHandlerRejectsConcurrentProbe(t *testing.T) {
	t.Parallel()

	started := make(chan struct{})
	release := make(chan struct{})
	executor := &fakeExecutor{execute: func(
		_ context.Context,
		request workercontracts.ProbeRequestV1,
	) workercontracts.ProbeResponseV1 {
		close(started)
		<-release
		return workerprobe.FailureResponse(request.RequestID, workercontracts.ProbeError)
	}}
	handler := testHandler(t, executor, time.Second, 1)
	firstRequest := validRequest(t)
	firstDone := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, firstRequest)
		firstDone <- recorder
	}()
	<-started

	second := httptest.NewRecorder()
	handler.ServeHTTP(second, validRequest(t))
	if second.Code != http.StatusServiceUnavailable || second.Body.Len() != 0 {
		close(release)
		<-firstDone
		t.Fatalf("status = %d, body = %q", second.Code, second.Body.String())
	}
	close(release)
	if first := <-firstDone; first.Code != http.StatusOK {
		t.Fatalf("first status = %d", first.Code)
	}
}

func TestHandlerAppliesExecutionTimeout(t *testing.T) {
	t.Parallel()

	executor := &fakeExecutor{execute: func(
		ctx context.Context,
		request workercontracts.ProbeRequestV1,
	) workercontracts.ProbeResponseV1 {
		<-ctx.Done()
		return workerprobe.FailureResponse(request.RequestID, workercontracts.Timeout)
	}}
	handler := testHandler(t, executor, time.Millisecond, 1)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, validRequest(t))
	response, err := workercontracts.DecodeProbeResponse(recorder.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if recorder.Code != http.StatusOK || response.Failure == nil ||
		response.Failure.Reason != workercontracts.Timeout {
		t.Fatalf("status = %d, response = %#v", recorder.Code, response)
	}
}

func TestHandlerRejectsInvalidExecutorResponse(t *testing.T) {
	t.Parallel()

	executor := &fakeExecutor{execute: func(
		context.Context,
		workercontracts.ProbeRequestV1,
	) workercontracts.ProbeResponseV1 {
		return workercontracts.ProbeResponseV1{}
	}}
	handler := testHandler(t, executor, time.Second, 1)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, validRequest(t))
	if recorder.Code != http.StatusInternalServerError || recorder.Body.Len() != 0 {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
}

func TestNewHandlerRejectsInvalidConfiguration(t *testing.T) {
	t.Parallel()

	if _, err := NewHandler(nil, time.Second, 1); err == nil {
		t.Fatal("missing executor was accepted")
	}
	if _, err := NewHandler(&fakeExecutor{}, 0, 1); err == nil {
		t.Fatal("zero timeout was accepted")
	}
	if _, err := NewHandler(&fakeExecutor{}, time.Second, 0); err == nil {
		t.Fatal("zero concurrency limit was accepted")
	}
}

func TestRouterRegistersTypedOperations(t *testing.T) {
	t.Parallel()

	handler := testHandler(t, &fakeExecutor{execute: func(
		_ context.Context,
		request workercontracts.ProbeRequestV1,
	) workercontracts.ProbeResponseV1 {
		return workerprobe.FailureResponse(request.RequestID, workercontracts.ProbeError)
	}}, time.Second, 1)
	router, err := NewRouter(handler)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, validRequest(t))
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d", recorder.Code)
	}

	missing := httptest.NewRecorder()
	router.ServeHTTP(missing, httptest.NewRequest(http.MethodPost, "/v1/missing", nil))
	if missing.Code != http.StatusNotFound {
		t.Fatalf("missing status = %d", missing.Code)
	}
}

func TestRouterRejectsInvalidOperationSets(t *testing.T) {
	t.Parallel()

	handler := testHandler(t, &fakeExecutor{}, time.Second, 1)
	var missing *Handler
	for name, operations := range map[string][]Operation{
		"empty":     nil,
		"nil":       {missing},
		"duplicate": {handler, handler},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if _, err := NewRouter(operations...); err == nil {
				t.Fatal("invalid operation set was accepted")
			}
		})
	}
}

type fakeExecutor struct {
	execute func(context.Context, workercontracts.ProbeRequestV1) workercontracts.ProbeResponseV1
	calls   int
}

func (executor *fakeExecutor) Execute(
	ctx context.Context,
	request workercontracts.ProbeRequestV1,
) workercontracts.ProbeResponseV1 {
	executor.calls++
	if executor.execute == nil {
		return workercontracts.ProbeResponseV1{}
	}
	return executor.execute(ctx, request)
}

func testHandler(
	t *testing.T,
	executor ProbeExecutor,
	timeout time.Duration,
	maxConcurrent int,
) *Handler {
	t.Helper()
	handler, err := NewHandler(executor, timeout, maxConcurrent)
	if err != nil {
		t.Fatal(err)
	}
	return handler
}

func validRequest(t *testing.T) *http.Request {
	t.Helper()
	request := httptest.NewRequest(
		http.MethodPost,
		probePath,
		strings.NewReader(string(readProbeRequest(t))),
	)
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	return request
}

func readProbeRequest(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile("../contracts/v1/examples/probe-request.json")
	if err != nil {
		t.Fatal(err)
	}
	return data
}

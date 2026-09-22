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
)

func TestStageJoinHandlerServesTypedResponse(t *testing.T) {
	t.Parallel()

	executor := &fakeStageJoinExecutor{execute: func(
		_ context.Context,
		request workercontracts.StageJoinRequestV1,
	) workercontracts.StageJoinResponseV1 {
		return stageJoinFailureResponse(
			request.RequestID,
			workercontracts.StageJoinFingerprintMismatch,
		)
	}}
	handler := testStageJoinHandler(t, executor, time.Second)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, validStageJoinRequest(t))

	response, err := workercontracts.DecodeStageJoinResponse(recorder.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if recorder.Code != http.StatusOK ||
		response.RequestID() != "request:join:01" ||
		response.Failure == nil ||
		response.Failure.Reason != workercontracts.StageJoinFingerprintMismatch {
		t.Fatalf("status = %d, response = %#v", recorder.Code, response)
	}
}

func TestStageJoinHandlerRejectsInvalidBodies(t *testing.T) {
	t.Parallel()

	for _, test := range []struct {
		name       string
		body       string
		wantStatus int
	}{
		{name: "malformed", body: "{", wantStatus: http.StatusBadRequest},
		{
			name: "wrong operation", body: string(readProbeRequest(t)),
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "oversized",
			body:       strings.Repeat("x", workercontracts.MaxJoinRequestBytes+1),
			wantStatus: http.StatusRequestEntityTooLarge,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			executor := &fakeStageJoinExecutor{}
			handler := testStageJoinHandler(t, executor, time.Second)
			request := httptest.NewRequest(
				http.MethodPost,
				stageJoinPath,
				strings.NewReader(test.body),
			)
			request.Header.Set("Content-Type", "application/json")
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)

			if recorder.Code != test.wantStatus ||
				recorder.Body.Len() != 0 ||
				executor.calls != 0 {
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

func TestStageJoinHandlerRejectsConcurrentRequest(t *testing.T) {
	t.Parallel()

	started := make(chan struct{})
	release := make(chan struct{})
	executor := &fakeStageJoinExecutor{execute: func(
		_ context.Context,
		request workercontracts.StageJoinRequestV1,
	) workercontracts.StageJoinResponseV1 {
		close(started)
		<-release
		return stageJoinFailureResponse(request.RequestID, workercontracts.StageJoinJoinError)
	}}
	handler := testStageJoinHandler(t, executor, time.Second)
	firstDone := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, validStageJoinRequest(t))
		firstDone <- recorder
	}()
	<-started

	second := httptest.NewRecorder()
	handler.ServeHTTP(second, validStageJoinRequest(t))
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

func TestStageJoinHandlerAppliesTimeout(t *testing.T) {
	t.Parallel()

	executor := &fakeStageJoinExecutor{execute: func(
		ctx context.Context,
		request workercontracts.StageJoinRequestV1,
	) workercontracts.StageJoinResponseV1 {
		<-ctx.Done()
		return stageJoinFailureResponse(request.RequestID, workercontracts.StageJoinTimeout)
	}}
	handler := testStageJoinHandler(t, executor, time.Millisecond)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, validStageJoinRequest(t))

	response, err := workercontracts.DecodeStageJoinResponse(recorder.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if recorder.Code != http.StatusOK || response.Failure == nil ||
		response.Failure.Reason != workercontracts.StageJoinTimeout {
		t.Fatalf("status = %d, response = %#v", recorder.Code, response)
	}
}

func TestStageJoinHandlerRejectsInvalidExecutorResponse(t *testing.T) {
	t.Parallel()

	handler := testStageJoinHandler(t, &fakeStageJoinExecutor{}, time.Second)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, validStageJoinRequest(t))
	if recorder.Code != http.StatusInternalServerError || recorder.Body.Len() != 0 {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
}

func TestNewStageJoinHandlerRejectsInvalidConfiguration(t *testing.T) {
	t.Parallel()

	if _, err := NewStageJoinHandler(nil, time.Second); err == nil {
		t.Fatal("missing executor was accepted")
	}
	if _, err := NewStageJoinHandler(&fakeStageJoinExecutor{}, 0); err == nil {
		t.Fatal("zero timeout was accepted")
	}
}

type fakeStageJoinExecutor struct {
	execute func(
		context.Context,
		workercontracts.StageJoinRequestV1,
	) workercontracts.StageJoinResponseV1
	calls int
}

func (executor *fakeStageJoinExecutor) Execute(
	ctx context.Context,
	request workercontracts.StageJoinRequestV1,
) workercontracts.StageJoinResponseV1 {
	executor.calls++
	if executor.execute == nil {
		return workercontracts.StageJoinResponseV1{}
	}
	return executor.execute(ctx, request)
}

func testStageJoinHandler(
	t *testing.T,
	executor StageJoinExecutor,
	timeout time.Duration,
) *StageJoinHandler {
	t.Helper()
	handler, err := NewStageJoinHandler(executor, timeout)
	if err != nil {
		t.Fatal(err)
	}
	return handler
}

func validStageJoinRequest(t *testing.T) *http.Request {
	t.Helper()
	request := httptest.NewRequest(
		http.MethodPost,
		stageJoinPath,
		strings.NewReader(string(readStageJoinRequest(t))),
	)
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	return request
}

func readStageJoinRequest(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile("../contracts/v1/examples/join-stage-request.json")
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func stageJoinFailureResponse(
	requestID string,
	reason workercontracts.StageJoinFailureReason,
) workercontracts.StageJoinResponseV1 {
	return workercontracts.StageJoinResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.StageJoinFailureResponseV1{
			Operation:     workercontracts.StageJoinV1,
			Reason:        reason,
			RequestID:     requestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status:        workercontracts.Failed,
		},
	}
}

package workerserver

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

func TestInspectJoinHandlerServesTypedResponse(t *testing.T) {
	t.Parallel()

	executor := &fakeInspectJoinExecutor{inspect: func(
		_ context.Context,
		request workercontracts.InspectJoinRequestV1,
	) workercontracts.InspectJoinResponseV1 {
		return inspectJoinSuccess(request.RequestID, workercontracts.InspectJoinPrepared)
	}}
	handler := testInspectJoinHandler(t, executor, time.Second)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, validInspectJoinRequest(t))

	response, err := workercontracts.DecodeInspectJoinResponse(recorder.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if recorder.Code != http.StatusOK ||
		response.RequestID() != "request:inspect:01" ||
		response.Success == nil ||
		response.Success.State != workercontracts.InspectJoinPrepared {
		t.Fatalf("status = %d, response = %#v", recorder.Code, response)
	}
}

func TestInspectJoinHandlerRejectsWrongOperation(t *testing.T) {
	t.Parallel()

	executor := &fakeInspectJoinExecutor{}
	handler := testInspectJoinHandler(t, executor, time.Second)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(
		recorder,
		requestWithBody(inspectJoinPath, readStageJoinRequest(t)),
	)
	if recorder.Code != http.StatusBadRequest || recorder.Body.Len() != 0 ||
		executor.calls != 0 {
		t.Fatalf(
			"status = %d, body = %q, executor calls = %d",
			recorder.Code,
			recorder.Body.String(),
			executor.calls,
		)
	}
}

func TestNewInspectJoinHandlerRejectsInvalidConfiguration(t *testing.T) {
	t.Parallel()

	if _, err := NewInspectJoinHandler(nil, time.Second); err == nil {
		t.Fatal("missing executor was accepted")
	}
	if _, err := NewInspectJoinHandler(&fakeInspectJoinExecutor{}, 0); err == nil {
		t.Fatal("zero timeout was accepted")
	}
}

type fakeInspectJoinExecutor struct {
	inspect func(
		context.Context,
		workercontracts.InspectJoinRequestV1,
	) workercontracts.InspectJoinResponseV1
	calls int
}

func (executor *fakeInspectJoinExecutor) Inspect(
	ctx context.Context,
	request workercontracts.InspectJoinRequestV1,
) workercontracts.InspectJoinResponseV1 {
	executor.calls++
	if executor.inspect == nil {
		return workercontracts.InspectJoinResponseV1{}
	}
	return executor.inspect(ctx, request)
}

func testInspectJoinHandler(
	t *testing.T,
	executor InspectJoinExecutor,
	timeout time.Duration,
) *InspectJoinHandler {
	t.Helper()
	handler, err := NewInspectJoinHandler(executor, timeout)
	if err != nil {
		t.Fatal(err)
	}
	return handler
}

func validInspectJoinRequest(t *testing.T) *http.Request {
	t.Helper()
	return requestWithBody(inspectJoinPath, readInspectJoinRequest(t))
}

func readInspectJoinRequest(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile("../contracts/v1/examples/join-inspect-request.json")
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func inspectJoinSuccess(
	requestID string,
	state workercontracts.InspectJoinState,
) workercontracts.InspectJoinResponseV1 {
	return workercontracts.InspectJoinResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.InspectJoinSuccessResponseV1{
			Operation:     workercontracts.InspectJoinV1,
			RequestID:     requestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			State:         state,
			Status:        workercontracts.Ok,
		},
	}
}

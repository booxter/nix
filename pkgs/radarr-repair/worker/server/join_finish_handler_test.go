package workerserver

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

func TestPublishHandlerServesTypedResponse(t *testing.T) {
	t.Parallel()

	executor := &fakePublishExecutor{publish: func(
		_ context.Context,
		request workercontracts.PublishRequestV1,
	) workercontracts.PublishResponseV1 {
		return publishFailureResponse(
			request.RequestID,
			workercontracts.PublishDestinationExists,
		)
	}}
	handler := testPublishHandler(t, executor, time.Second)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, validPublishRequest(t))

	response, err := workercontracts.DecodePublishResponse(recorder.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if recorder.Code != http.StatusOK ||
		response.RequestID() != "request:publish:01" ||
		response.Failure == nil ||
		response.Failure.Reason != workercontracts.PublishDestinationExists {
		t.Fatalf("status = %d, response = %#v", recorder.Code, response)
	}
}

func TestDiscardHandlerServesTypedResponse(t *testing.T) {
	t.Parallel()

	executor := &fakeDiscardExecutor{discard: func(
		_ context.Context,
		request workercontracts.DiscardRequestV1,
	) workercontracts.DiscardResponseV1 {
		return discardFailureResponse(
			request.RequestID,
			workercontracts.DiscardArtifactPublished,
		)
	}}
	handler := testDiscardHandler(t, executor, time.Second)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, validDiscardRequest(t))

	response, err := workercontracts.DecodeDiscardResponse(recorder.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if recorder.Code != http.StatusOK ||
		response.RequestID() != "request:discard:01" ||
		response.Failure == nil ||
		response.Failure.Reason != workercontracts.DiscardArtifactPublished {
		t.Fatalf("status = %d, response = %#v", recorder.Code, response)
	}
}

func TestJoinFinishHandlersRejectWrongOperation(t *testing.T) {
	t.Parallel()

	publishExecutor := &fakePublishExecutor{}
	publishHandler := testPublishHandler(t, publishExecutor, time.Second)
	publishRecorder := httptest.NewRecorder()
	publishHandler.ServeHTTP(publishRecorder, requestWithBody(publishPath, readDiscardRequest(t)))
	if publishRecorder.Code != http.StatusBadRequest || publishExecutor.calls != 0 {
		t.Fatalf(
			"publish status = %d, executor calls = %d",
			publishRecorder.Code,
			publishExecutor.calls,
		)
	}

	discardExecutor := &fakeDiscardExecutor{}
	discardHandler := testDiscardHandler(t, discardExecutor, time.Second)
	discardRecorder := httptest.NewRecorder()
	discardHandler.ServeHTTP(discardRecorder, requestWithBody(discardPath, readPublishRequest(t)))
	if discardRecorder.Code != http.StatusBadRequest || discardExecutor.calls != 0 {
		t.Fatalf(
			"discard status = %d, executor calls = %d",
			discardRecorder.Code,
			discardExecutor.calls,
		)
	}
}

func TestJoinFinishHandlersRejectConcurrentRequest(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		path    string
		body    []byte
		handler func(chan struct{}, chan struct{}) http.Handler
	}{
		{
			name: "publish",
			path: publishPath,
			body: readPublishRequest(t),
			handler: func(started chan struct{}, release chan struct{}) http.Handler {
				return testPublishHandler(t, &fakePublishExecutor{publish: func(
					_ context.Context,
					request workercontracts.PublishRequestV1,
				) workercontracts.PublishResponseV1 {
					close(started)
					<-release
					return publishFailureResponse(
						request.RequestID,
						workercontracts.PublishErrorReason,
					)
				}}, time.Second)
			},
		},
		{
			name: "discard",
			path: discardPath,
			body: readDiscardRequest(t),
			handler: func(started chan struct{}, release chan struct{}) http.Handler {
				return testDiscardHandler(t, &fakeDiscardExecutor{discard: func(
					_ context.Context,
					request workercontracts.DiscardRequestV1,
				) workercontracts.DiscardResponseV1 {
					close(started)
					<-release
					return discardFailureResponse(
						request.RequestID,
						workercontracts.DiscardErrorReason,
					)
				}}, time.Second)
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			started := make(chan struct{})
			release := make(chan struct{})
			handler := test.handler(started, release)
			firstDone := make(chan *httptest.ResponseRecorder, 1)
			go func() {
				recorder := httptest.NewRecorder()
				handler.ServeHTTP(recorder, requestWithBody(test.path, test.body))
				firstDone <- recorder
			}()
			<-started

			second := httptest.NewRecorder()
			handler.ServeHTTP(second, requestWithBody(test.path, test.body))
			if second.Code != http.StatusServiceUnavailable || second.Body.Len() != 0 {
				close(release)
				<-firstDone
				t.Fatalf("status = %d, body = %q", second.Code, second.Body.String())
			}
			close(release)
			if first := <-firstDone; first.Code != http.StatusOK {
				t.Fatalf("first status = %d", first.Code)
			}
		})
	}
}

func TestJoinFinishHandlersRejectInvalidBodies(t *testing.T) {
	t.Parallel()

	for _, test := range []struct {
		name       string
		handler    http.Handler
		path       string
		body       string
		wantStatus int
	}{
		{
			name:       "publish malformed",
			handler:    testPublishHandler(t, &fakePublishExecutor{}, time.Second),
			path:       publishPath,
			body:       "{",
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "discard oversized",
			handler:    testDiscardHandler(t, &fakeDiscardExecutor{}, time.Second),
			path:       discardPath,
			body:       strings.Repeat("x", workercontracts.MaxJoinRequestBytes+1),
			wantStatus: http.StatusRequestEntityTooLarge,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			test.handler.ServeHTTP(recorder, requestWithBody(test.path, []byte(test.body)))
			if recorder.Code != test.wantStatus || recorder.Body.Len() != 0 {
				t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
			}
		})
	}
}

func TestJoinFinishHandlersApplyTimeout(t *testing.T) {
	t.Parallel()

	publishExecutor := &fakePublishExecutor{publish: func(
		ctx context.Context,
		request workercontracts.PublishRequestV1,
	) workercontracts.PublishResponseV1 {
		<-ctx.Done()
		return publishFailureResponse(request.RequestID, workercontracts.PublishErrorReason)
	}}
	publishHandler := testPublishHandler(t, publishExecutor, time.Millisecond)
	recorder := httptest.NewRecorder()
	publishHandler.ServeHTTP(recorder, validPublishRequest(t))
	if recorder.Code != http.StatusOK {
		t.Fatalf("publish status = %d", recorder.Code)
	}

	discardExecutor := &fakeDiscardExecutor{discard: func(
		ctx context.Context,
		request workercontracts.DiscardRequestV1,
	) workercontracts.DiscardResponseV1 {
		<-ctx.Done()
		return discardFailureResponse(request.RequestID, workercontracts.DiscardErrorReason)
	}}
	discardHandler := testDiscardHandler(t, discardExecutor, time.Millisecond)
	recorder = httptest.NewRecorder()
	discardHandler.ServeHTTP(recorder, validDiscardRequest(t))
	if recorder.Code != http.StatusOK {
		t.Fatalf("discard status = %d", recorder.Code)
	}
}

func TestJoinFinishHandlersRejectInvalidExecutorResponse(t *testing.T) {
	t.Parallel()

	publish := testPublishHandler(t, &fakePublishExecutor{}, time.Second)
	recorder := httptest.NewRecorder()
	publish.ServeHTTP(recorder, validPublishRequest(t))
	if recorder.Code != http.StatusInternalServerError || recorder.Body.Len() != 0 {
		t.Fatalf("publish status = %d, body = %q", recorder.Code, recorder.Body.String())
	}

	discard := testDiscardHandler(t, &fakeDiscardExecutor{}, time.Second)
	recorder = httptest.NewRecorder()
	discard.ServeHTTP(recorder, validDiscardRequest(t))
	if recorder.Code != http.StatusInternalServerError || recorder.Body.Len() != 0 {
		t.Fatalf("discard status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
}

func TestNewJoinFinishHandlersRejectInvalidConfiguration(t *testing.T) {
	t.Parallel()

	if _, err := NewPublishHandler(nil, time.Second); err == nil {
		t.Fatal("missing publish executor was accepted")
	}
	if _, err := NewPublishHandler(&fakePublishExecutor{}, 0); err == nil {
		t.Fatal("zero publish timeout was accepted")
	}
	if _, err := NewDiscardHandler(nil, time.Second); err == nil {
		t.Fatal("missing discard executor was accepted")
	}
	if _, err := NewDiscardHandler(&fakeDiscardExecutor{}, 0); err == nil {
		t.Fatal("zero discard timeout was accepted")
	}
}

type fakePublishExecutor struct {
	publish func(
		context.Context,
		workercontracts.PublishRequestV1,
	) workercontracts.PublishResponseV1
	calls int
}

func (executor *fakePublishExecutor) Publish(
	ctx context.Context,
	request workercontracts.PublishRequestV1,
) workercontracts.PublishResponseV1 {
	executor.calls++
	if executor.publish == nil {
		return workercontracts.PublishResponseV1{}
	}
	return executor.publish(ctx, request)
}

type fakeDiscardExecutor struct {
	discard func(
		context.Context,
		workercontracts.DiscardRequestV1,
	) workercontracts.DiscardResponseV1
	calls int
}

func (executor *fakeDiscardExecutor) Discard(
	ctx context.Context,
	request workercontracts.DiscardRequestV1,
) workercontracts.DiscardResponseV1 {
	executor.calls++
	if executor.discard == nil {
		return workercontracts.DiscardResponseV1{}
	}
	return executor.discard(ctx, request)
}

func testPublishHandler(
	t *testing.T,
	executor PublishExecutor,
	timeout time.Duration,
) *PublishHandler {
	t.Helper()
	handler, err := NewPublishHandler(executor, timeout)
	if err != nil {
		t.Fatal(err)
	}
	return handler
}

func testDiscardHandler(
	t *testing.T,
	executor DiscardExecutor,
	timeout time.Duration,
) *DiscardHandler {
	t.Helper()
	handler, err := NewDiscardHandler(executor, timeout)
	if err != nil {
		t.Fatal(err)
	}
	return handler
}

func validPublishRequest(t *testing.T) *http.Request {
	t.Helper()
	return requestWithBody(publishPath, readPublishRequest(t))
}

func validDiscardRequest(t *testing.T) *http.Request {
	t.Helper()
	return requestWithBody(discardPath, readDiscardRequest(t))
}

func requestWithBody(path string, body []byte) *http.Request {
	request := httptest.NewRequest(http.MethodPost, path, strings.NewReader(string(body)))
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	return request
}

func readPublishRequest(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile("../contracts/v1/examples/join-publish-request.json")
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func readDiscardRequest(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile("../contracts/v1/examples/join-discard-request.json")
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func publishFailureResponse(
	requestID string,
	reason workercontracts.PublishFailureReason,
) workercontracts.PublishResponseV1 {
	return workercontracts.PublishResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.PublishFailureResponseV1{
			Operation:     workercontracts.PublishV1,
			Reason:        reason,
			RequestID:     requestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status:        workercontracts.Failed,
		},
	}
}

func discardFailureResponse(
	requestID string,
	reason workercontracts.DiscardFailureReason,
) workercontracts.DiscardResponseV1 {
	return workercontracts.DiscardResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.DiscardFailureResponseV1{
			Operation:     workercontracts.DiscardV1,
			Reason:        reason,
			RequestID:     requestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status:        workercontracts.Failed,
		},
	}
}

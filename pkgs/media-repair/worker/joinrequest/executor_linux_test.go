package joinrequest

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/joinstage"
	"github.com/booxter/nix-config/media-repair/worker/joinstate"
)

const stagedFingerprint = "sha256:4444444444444444444444444444444444444444444444444444444444444444"

func TestExecutorPersistsStagedResultBeforeReturning(t *testing.T) {
	t.Parallel()

	store := newStore(t)
	stager := &fakeStager{result: successfulStage()}
	executor := newExecutor(t, store, stager)
	request := stageRequest(t)

	response := executor.Execute(context.Background(), request)
	assertSuccess(t, response, request.RequestID)
	if stager.calls != 1 {
		t.Fatalf("stage calls = %d, want 1", stager.calls)
	}
	execution, found, err := store.Get(request.ExecutionID)
	if err != nil {
		t.Fatal(err)
	}
	if !found || execution.State != joinstate.Staged || execution.Staged == nil {
		t.Fatalf("stored execution = %#v", execution)
	}
	if execution.Staged.Fingerprint != stagedFingerprint {
		t.Fatalf("stored fingerprint = %q", execution.Staged.Fingerprint)
	}
	if _, err := workercontracts.EncodeStageJoinResponse(response); err != nil {
		t.Fatalf("encode response: %v", err)
	}
}

func TestExecutorReturnsStoredStagedResultForRetry(t *testing.T) {
	t.Parallel()

	store := newStore(t)
	stager := &fakeStager{result: successfulStage()}
	executor := newExecutor(t, store, stager)
	request := stageRequest(t)
	assertSuccess(t, executor.Execute(context.Background(), request), request.RequestID)

	request.RequestID = "request:join:retry"
	response := executor.Execute(context.Background(), request)
	assertSuccess(t, response, request.RequestID)
	if stager.calls != 1 {
		t.Fatalf("stage calls = %d, want 1", stager.calls)
	}
}

func TestExecutorReturnsStoredFailureForRetry(t *testing.T) {
	t.Parallel()

	store := newStore(t)
	stager := &fakeStager{err: &joinstage.Failure{
		Reason: workercontracts.StageJoinFingerprintMismatch,
	}}
	executor := newExecutor(t, store, stager)
	request := stageRequest(t)
	assertFailure(
		t,
		executor.Execute(context.Background(), request),
		request.RequestID,
		workercontracts.StageJoinFingerprintMismatch,
	)

	request.RequestID = "request:join:retry"
	assertFailure(
		t,
		executor.Execute(context.Background(), request),
		request.RequestID,
		workercontracts.StageJoinFingerprintMismatch,
	)
	if stager.calls != 1 {
		t.Fatalf("stage calls = %d, want 1", stager.calls)
	}
}

func TestExecutorRejectsExecutionReuseForDifferentWork(t *testing.T) {
	t.Parallel()

	store := newStore(t)
	stager := &fakeStager{result: successfulStage()}
	executor := newExecutor(t, store, stager)
	request := stageRequest(t)
	assertSuccess(t, executor.Execute(context.Background(), request), request.RequestID)

	request.RequestID = "request:join:conflict"
	request.ExpectedDurationMS++
	assertFailure(
		t,
		executor.Execute(context.Background(), request),
		request.RequestID,
		workercontracts.StageJoinExecutionConflict,
	)
	if stager.calls != 1 {
		t.Fatalf("stage calls = %d, want 1", stager.calls)
	}
}

func TestExecutorResumesPreparedExecution(t *testing.T) {
	t.Parallel()

	store := newStore(t)
	request := stageRequest(t)
	if _, _, err := store.Prepare(request, testTime()); err != nil {
		t.Fatal(err)
	}
	stager := &fakeStager{result: successfulStage()}
	executor := newExecutor(t, store, stager)

	assertSuccess(t, executor.Execute(context.Background(), request), request.RequestID)
	if stager.calls != 1 {
		t.Fatalf("stage calls = %d, want 1", stager.calls)
	}
}

func TestExecutorRetriesAfterStagedResultWasNotPersisted(t *testing.T) {
	t.Parallel()

	store := newStore(t)
	transitions := &failingTransitionStore{Store: store, failStagedOnce: true}
	stager := &fakeStager{result: successfulStage()}
	executor := newExecutor(t, transitions, stager)
	request := stageRequest(t)

	assertFailure(
		t,
		executor.Execute(context.Background(), request),
		request.RequestID,
		workercontracts.StageJoinInternalError,
	)
	request.RequestID = "request:join:retry"
	assertSuccess(t, executor.Execute(context.Background(), request), request.RequestID)
	if stager.calls != 2 {
		t.Fatalf("stage calls = %d, want 2", stager.calls)
	}
}

func TestExecutorDoesNotRunStagesConcurrently(t *testing.T) {
	t.Parallel()

	store := newStore(t)
	stager := &concurrencyCheckingStager{}
	executor := newExecutor(t, store, stager)
	request := stageRequest(t)

	const requests = 8
	start := make(chan struct{})
	var wait sync.WaitGroup
	for index := range requests {
		wait.Add(1)
		go func() {
			defer wait.Done()
			current := request
			current.ExecutionID += string(rune('a' + index))
			current.RequestID += string(rune('a' + index))
			<-start
			response := executor.Execute(context.Background(), current)
			if response.Kind != workercontracts.ProbeResponseSucceeded {
				t.Errorf("response = %#v", response)
			}
		}()
	}
	close(start)
	wait.Wait()
	if stager.concurrent.Load() {
		t.Fatal("stages overlapped")
	}
}

func TestNewExecutorRequiresDependencies(t *testing.T) {
	t.Parallel()

	store := newStore(t)
	stager := &fakeStager{result: successfulStage()}
	clock := fixedClock{now: testTime()}
	for name, dependencies := range map[string]Dependencies{
		"store":  {Stager: stager, Clock: clock},
		"stager": {Store: store, Clock: clock},
		"clock":  {Store: store, Stager: stager},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := NewExecutor(dependencies); err == nil {
				t.Fatal("NewExecutor succeeded")
			}
		})
	}
}

type fakeStager struct {
	result joinstage.Result
	err    error
	calls  int
}

func (stager *fakeStager) StageOrRecover(
	context.Context,
	joinstate.Execution,
) (joinstage.Result, error) {
	stager.calls++
	return stager.result, stager.err
}

type concurrencyCheckingStager struct {
	active     atomic.Bool
	concurrent atomic.Bool
}

func (stager *concurrencyCheckingStager) StageOrRecover(
	context.Context,
	joinstate.Execution,
) (joinstage.Result, error) {
	if !stager.active.CompareAndSwap(false, true) {
		stager.concurrent.Store(true)
	}
	time.Sleep(time.Millisecond)
	stager.active.Store(false)
	return successfulStage(), nil
}

type failingTransitionStore struct {
	*joinstate.Store
	failStagedOnce bool
}

func (store *failingTransitionStore) MarkStaged(
	executionID string,
	artifactID string,
	staged joinstate.StagedArtifact,
	updatedAt time.Time,
) (joinstate.Execution, bool, error) {
	if store.failStagedOnce {
		store.failStagedOnce = false
		return joinstate.Execution{}, false, errors.New("write interrupted")
	}
	return store.Store.MarkStaged(executionID, artifactID, staged, updatedAt)
}

type fixedClock struct {
	now time.Time
}

func (clock fixedClock) Now() time.Time {
	return clock.now
}

func newExecutor(t *testing.T, store Store, stager Stager) *Executor {
	t.Helper()
	executor, err := NewExecutor(Dependencies{
		Store: store, Stager: stager, Clock: fixedClock{now: testTime()},
	})
	if err != nil {
		t.Fatal(err)
	}
	return executor
}

func newStore(t *testing.T) *joinstate.Store {
	t.Helper()
	store, err := joinstate.New(filepath.Join(t.TempDir(), "join-state"))
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func stageRequest(t *testing.T) workercontracts.StageJoinRequestV1 {
	t.Helper()
	data, err := os.ReadFile("../contracts/v1/examples/join-stage-request.json")
	if err != nil {
		t.Fatal(err)
	}
	request, err := workercontracts.DecodeStageJoinRequest(data)
	if err != nil {
		t.Fatal(err)
	}
	return request
}

func successfulStage() joinstage.Result {
	return joinstage.Result{
		Fingerprint: stagedFingerprint,
		SizeBytes:   8_390_000_000,
		Evidence: controller.ProbeEvidence{
			Format: controller.ProbeFormat{
				Names: []string{},
				Tags:  []controller.ProbeTag{},
			},
			Streams:  []controller.ProbeStream{},
			Programs: []controller.ProbeProgram{},
			Chapters: []controller.ProbeChapter{},
		},
	}
}

func assertSuccess(
	t *testing.T,
	response workercontracts.StageJoinResponseV1,
	requestID string,
) {
	t.Helper()
	if response.Kind != workercontracts.ProbeResponseSucceeded ||
		response.Success == nil ||
		response.Success.RequestID != requestID ||
		response.Success.ArtifactFingerprint != stagedFingerprint {
		t.Fatalf("stage response = %#v", response)
	}
}

func assertFailure(
	t *testing.T,
	response workercontracts.StageJoinResponseV1,
	requestID string,
	reason workercontracts.StageJoinFailureReason,
) {
	t.Helper()
	if response.Kind != workercontracts.ProbeResponseFailed ||
		response.Failure == nil ||
		response.Failure.RequestID != requestID ||
		response.Failure.Reason != reason {
		t.Fatalf("stage response = %#v", response)
	}
}

func testTime() time.Time {
	return time.Date(2026, time.September, 13, 12, 0, 0, 0, time.UTC)
}

package joinfinish

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/joinstate"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
)

func TestPublishUsesStoredJoinAuthorization(t *testing.T) {
	t.Parallel()

	store, staged := newStagedStore(t)
	artifacts := &fakeArtifacts{
		path: []string{"Movie.Release", "radarr-repair-result.mkv"},
	}
	executor := newExecutor(t, store, artifacts)
	request := publishRequest(staged)
	response := executor.Publish(context.Background(), request)

	assertPublishSuccess(t, response, request.RequestID, staged, artifacts.path)
	if len(artifacts.calls) != 1 {
		t.Fatalf("publish calls = %d, want 1", len(artifacts.calls))
	}
	wantPaths := make([][]string, len(staged.Specification.Parts))
	for index, part := range staged.Specification.Parts {
		wantPaths[index] = part.PathComponents
	}
	wantCall := publishCall{
		rootID:      staged.Specification.RootID,
		artifactID:  staged.ArtifactID,
		container:   staged.Specification.OutputContainer,
		fingerprint: staged.Staged.Fingerprint,
		inputPaths:  wantPaths,
	}
	if !reflect.DeepEqual(artifacts.calls[0], wantCall) {
		t.Fatalf("publish call = %#v, want %#v", artifacts.calls[0], wantCall)
	}
	stored, found, err := store.FindByArtifactID(staged.ArtifactID)
	if err != nil || !found || stored.State != joinstate.Published || stored.Published == nil ||
		!reflect.DeepEqual(stored.Published.PathComponents, artifacts.path) {
		t.Fatalf("stored publication: found = %t, execution = %#v, error = %v", found, stored, err)
	}
}

func TestPublishReturnsStoredResultOnRetry(t *testing.T) {
	t.Parallel()

	store, staged := newStagedStore(t)
	published := joinstate.PublishedArtifact{
		RootID:         staged.Specification.RootID,
		PathComponents: []string{"Movie.Release", "existing.mkv"},
	}
	if _, _, err := store.MarkPublished(
		staged.ExecutionID,
		staged.ArtifactID,
		staged.Staged.Fingerprint,
		published,
		testTime().Add(time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	artifacts := &fakeArtifacts{err: errors.New("must not publish again")}
	executor := newExecutor(t, store, artifacts)
	request := publishRequest(staged)

	response := executor.Publish(context.Background(), request)
	assertPublishSuccess(
		t,
		response,
		request.RequestID,
		staged,
		published.PathComponents,
	)
	if len(artifacts.calls) != 0 {
		t.Fatalf("publish calls = %d, want 0", len(artifacts.calls))
	}
}

func TestPublishRejectsUnauthorizedArtifactState(t *testing.T) {
	t.Parallel()

	t.Run("missing", func(t *testing.T) {
		store, staged := newStagedStore(t)
		executor := newExecutor(t, store, &fakeArtifacts{})
		request := publishRequest(staged)
		request.ArtifactID = "artifact:0000000000000000000000000000000000000000000000000000000000000000"
		assertPublishFailure(
			t,
			executor.Publish(context.Background(), request),
			workercontracts.PublishArtifactNotFound,
		)
	})

	t.Run("fingerprint mismatch", func(t *testing.T) {
		store, staged := newStagedStore(t)
		executor := newExecutor(t, store, &fakeArtifacts{})
		request := publishRequest(staged)
		request.ArtifactFingerprint = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
		assertPublishFailure(
			t,
			executor.Publish(context.Background(), request),
			workercontracts.PublishArtifactFingerprintMismatch,
		)
	})

	t.Run("not staged", func(t *testing.T) {
		store, prepared := newPreparedStore(t)
		executor := newExecutor(t, store, &fakeArtifacts{})
		request := workercontracts.PublishRequestV1{
			ArtifactFingerprint: "sha256:4444444444444444444444444444444444444444444444444444444444444444",
			ArtifactID:          prepared.ArtifactID,
			Operation:           workercontracts.PublishV1,
			RequestID:           "request:publish:not-staged",
			SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
		}
		assertPublishFailure(
			t,
			executor.Publish(context.Background(), request),
			workercontracts.PublishArtifactNotStaged,
		)
	})

	t.Run("failed", func(t *testing.T) {
		store, prepared := newPreparedStore(t)
		if _, _, err := store.MarkStageFailed(
			prepared.ExecutionID,
			workercontracts.StageJoinJoinError,
			testTime(),
		); err != nil {
			t.Fatal(err)
		}
		executor := newExecutor(t, store, &fakeArtifacts{})
		request := workercontracts.PublishRequestV1{
			ArtifactFingerprint: "sha256:4444444444444444444444444444444444444444444444444444444444444444",
			ArtifactID:          prepared.ArtifactID,
			Operation:           workercontracts.PublishV1,
			RequestID:           "request:publish:failed",
			SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
		}
		assertPublishFailure(
			t,
			executor.Publish(context.Background(), request),
			workercontracts.PublishArtifactNotStaged,
		)
	})

	t.Run("discarded", func(t *testing.T) {
		store, staged := newStagedStore(t)
		if _, _, err := store.MarkDiscarded(
			staged.ExecutionID,
			staged.ArtifactID,
			staged.Staged.Fingerprint,
			testTime().Add(time.Minute),
		); err != nil {
			t.Fatal(err)
		}
		executor := newExecutor(t, store, &fakeArtifacts{})
		assertPublishFailure(
			t,
			executor.Publish(context.Background(), publishRequest(staged)),
			workercontracts.PublishArtifactNotStaged,
		)
	})
}

func TestPublishMapsFilesystemFailures(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		err    error
		reason workercontracts.PublishFailureReason
	}{
		{
			name:   "artifact missing",
			err:    &mediafile.Failure{Kind: mediafile.FailureFileUnavailable},
			reason: workercontracts.PublishArtifactNotFound,
		},
		{
			name:   "fingerprint changed",
			err:    &mediafile.Failure{Kind: mediafile.FailureFingerprintMismatch},
			reason: workercontracts.PublishArtifactFingerprintMismatch,
		},
		{
			name:   "destination exists",
			err:    &mediafile.Failure{Kind: mediafile.FailureDestinationExists},
			reason: workercontracts.PublishDestinationExists,
		},
		{
			name:   "publish failed",
			err:    &mediafile.Failure{Kind: mediafile.FailureInvalidPath},
			reason: workercontracts.PublishErrorReason,
		},
		{
			name:   "internal failure",
			err:    errors.New("unexpected failure"),
			reason: workercontracts.PublishInternalError,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			store, staged := newStagedStore(t)
			executor := newExecutor(t, store, &fakeArtifacts{err: test.err})
			assertPublishFailure(
				t,
				executor.Publish(context.Background(), publishRequest(staged)),
				test.reason,
			)
		})
	}
}

func TestPublishRecoversAfterStateWriteFailure(t *testing.T) {
	t.Parallel()

	store, staged := newStagedStore(t)
	failingStore := &failingPublishStore{Store: store, failOnce: true}
	artifacts := &fakeArtifacts{path: []string{"Movie.Release", "result.mkv"}}
	executor := newExecutor(t, failingStore, artifacts)
	request := publishRequest(staged)

	assertPublishFailure(
		t,
		executor.Publish(context.Background(), request),
		workercontracts.PublishInternalError,
	)
	response := executor.Publish(context.Background(), request)
	assertPublishSuccess(t, response, request.RequestID, staged, artifacts.path)
	if len(artifacts.calls) != 2 {
		t.Fatalf("publish calls = %d, want 2", len(artifacts.calls))
	}
}

type publishCall struct {
	rootID      string
	artifactID  string
	container   workercontracts.OutputContainer
	fingerprint string
	inputPaths  [][]string
}

type fakeArtifacts struct {
	path        []string
	err         error
	calls       []publishCall
	removeCalls []discardCall
	removeErr   error
	removed     bool
}

func (artifacts *fakeArtifacts) PublishCompleted(
	rootID string,
	artifactID string,
	container workercontracts.OutputContainer,
	fingerprint string,
	inputPaths [][]string,
) ([]string, error) {
	paths := make([][]string, len(inputPaths))
	for index, path := range inputPaths {
		paths[index] = append([]string(nil), path...)
	}
	artifacts.calls = append(artifacts.calls, publishCall{
		rootID: rootID, artifactID: artifactID, container: container,
		fingerprint: fingerprint, inputPaths: paths,
	})
	return append([]string(nil), artifacts.path...), artifacts.err
}

type discardCall struct {
	rootID      string
	artifactID  string
	container   workercontracts.OutputContainer
	fingerprint string
}

func (artifacts *fakeArtifacts) RemoveCompleted(
	rootID string,
	artifactID string,
	container workercontracts.OutputContainer,
	fingerprint string,
) (bool, error) {
	artifacts.removeCalls = append(artifacts.removeCalls, discardCall{
		rootID: rootID, artifactID: artifactID, container: container,
		fingerprint: fingerprint,
	})
	return artifacts.removed, artifacts.removeErr
}

type failingPublishStore struct {
	*joinstate.Store
	failOnce bool
}

func (store *failingPublishStore) MarkPublished(
	executionID string,
	artifactID string,
	fingerprint string,
	published joinstate.PublishedArtifact,
	updatedAt time.Time,
) (joinstate.Execution, bool, error) {
	if store.failOnce {
		store.failOnce = false
		return joinstate.Execution{}, false, errors.New("write interrupted")
	}
	return store.Store.MarkPublished(
		executionID,
		artifactID,
		fingerprint,
		published,
		updatedAt,
	)
}

type fixedClock struct {
	now time.Time
}

func (clock fixedClock) Now() time.Time {
	return clock.now
}

func newExecutor(t *testing.T, store Store, artifacts Artifacts) *Executor {
	t.Helper()
	executor, err := NewExecutor(Dependencies{
		Store: store, Artifacts: artifacts, Clock: fixedClock{now: testTime()},
	})
	if err != nil {
		t.Fatal(err)
	}
	return executor
}

func newPreparedStore(t *testing.T) (*joinstate.Store, joinstate.Execution) {
	t.Helper()
	store, err := joinstate.New(filepath.Join(t.TempDir(), "join-state"))
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile("../contracts/v1/examples/join-stage-request.json")
	if err != nil {
		t.Fatal(err)
	}
	request, err := workercontracts.DecodeStageJoinRequest(data)
	if err != nil {
		t.Fatal(err)
	}
	prepared, _, err := store.Prepare(request, testTime().Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	return store, prepared
}

func newStagedStore(t *testing.T) (*joinstate.Store, joinstate.Execution) {
	t.Helper()
	store, prepared := newPreparedStore(t)
	data, err := os.ReadFile("../contracts/v1/examples/join-stage-response-ok.json")
	if err != nil {
		t.Fatal(err)
	}
	response, err := workercontracts.DecodeStageJoinResponse(data)
	if err != nil || response.Success == nil {
		t.Fatalf("decode staged response: %#v, error = %v", response, err)
	}
	staged, _, err := store.MarkStaged(
		prepared.ExecutionID,
		prepared.ArtifactID,
		joinstate.StagedArtifact{
			Fingerprint: response.Success.ArtifactFingerprint,
			SizeBytes:   response.Success.SizeBytes,
			Evidence:    response.Success.Evidence,
		},
		testTime(),
	)
	if err != nil {
		t.Fatal(err)
	}
	return store, staged
}

func publishRequest(execution joinstate.Execution) workercontracts.PublishRequestV1 {
	return workercontracts.PublishRequestV1{
		ArtifactFingerprint: execution.Staged.Fingerprint,
		ArtifactID:          execution.ArtifactID,
		Operation:           workercontracts.PublishV1,
		RequestID:           "request:publish:test",
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	}
}

func assertPublishSuccess(
	t *testing.T,
	response workercontracts.PublishResponseV1,
	requestID string,
	execution joinstate.Execution,
	path []string,
) {
	t.Helper()
	if response.Kind != workercontracts.ProbeResponseSucceeded || response.Success == nil ||
		response.Success.RequestID != requestID ||
		response.Success.ArtifactID != execution.ArtifactID ||
		response.Success.ArtifactFingerprint != execution.Staged.Fingerprint ||
		response.Success.RootID != execution.Specification.RootID ||
		!reflect.DeepEqual(response.Success.PathComponents, path) {
		t.Fatalf("publish response = %#v", response)
	}
	if _, err := workercontracts.EncodePublishResponse(response); err != nil {
		t.Fatalf("encode publish response: %v", err)
	}
}

func assertPublishFailure(
	t *testing.T,
	response workercontracts.PublishResponseV1,
	reason workercontracts.PublishFailureReason,
) {
	t.Helper()
	if response.Kind != workercontracts.ProbeResponseFailed || response.Failure == nil ||
		response.Failure.Reason != reason {
		t.Fatalf("publish response = %#v", response)
	}
	if _, err := workercontracts.EncodePublishResponse(response); err != nil {
		t.Fatalf("encode publish response: %v", err)
	}
}

func testTime() time.Time {
	return time.Date(2026, time.September, 13, 20, 0, 0, 0, time.UTC)
}

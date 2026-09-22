package joinfinish

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/joinstate"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
)

func TestDiscardUsesStoredJoinAuthorization(t *testing.T) {
	t.Parallel()

	store, staged := newStagedStore(t)
	artifacts := &fakeArtifacts{removed: true}
	executor := newExecutor(t, store, artifacts)
	request := discardRequest(staged)
	response := executor.Discard(context.Background(), request)

	assertDiscardSuccess(t, response, request.RequestID, staged)
	wantCall := discardCall{
		rootID:      staged.Specification.RootID,
		artifactID:  staged.ArtifactID,
		container:   staged.Specification.OutputContainer,
		fingerprint: staged.Staged.Fingerprint,
	}
	if len(artifacts.removeCalls) != 1 ||
		!reflect.DeepEqual(artifacts.removeCalls[0], wantCall) {
		t.Fatalf("discard calls = %#v, want %#v", artifacts.removeCalls, wantCall)
	}
	stored, found, err := store.FindByArtifactID(staged.ArtifactID)
	if err != nil || !found || stored.State != joinstate.Discarded {
		t.Fatalf("stored discard: found = %t, execution = %#v, error = %v", found, stored, err)
	}
}

func TestDiscardReturnsStoredResultOnRetry(t *testing.T) {
	t.Parallel()

	store, staged := newStagedStore(t)
	if _, _, err := store.MarkDiscarded(
		staged.ExecutionID,
		staged.ArtifactID,
		staged.Staged.Fingerprint,
		testTime().Add(time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	artifacts := &fakeArtifacts{removeErr: errors.New("must not discard again")}
	executor := newExecutor(t, store, artifacts)
	request := discardRequest(staged)

	assertDiscardSuccess(
		t,
		executor.Discard(context.Background(), request),
		request.RequestID,
		staged,
	)
	if len(artifacts.removeCalls) != 0 {
		t.Fatalf("discard calls = %d, want 0", len(artifacts.removeCalls))
	}
}

func TestDiscardRejectsUnauthorizedArtifactState(t *testing.T) {
	t.Parallel()

	t.Run("missing", func(t *testing.T) {
		store, staged := newStagedStore(t)
		executor := newExecutor(t, store, &fakeArtifacts{})
		request := discardRequest(staged)
		request.ArtifactID = "artifact:0000000000000000000000000000000000000000000000000000000000000000"
		assertDiscardFailure(
			t,
			executor.Discard(context.Background(), request),
			workercontracts.DiscardArtifactNotFound,
		)
	})

	t.Run("fingerprint mismatch", func(t *testing.T) {
		store, staged := newStagedStore(t)
		executor := newExecutor(t, store, &fakeArtifacts{})
		request := discardRequest(staged)
		request.ArtifactFingerprint = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
		assertDiscardFailure(
			t,
			executor.Discard(context.Background(), request),
			workercontracts.DiscardArtifactFingerprintMismatch,
		)
	})

	t.Run("not staged", func(t *testing.T) {
		store, prepared := newPreparedStore(t)
		executor := newExecutor(t, store, &fakeArtifacts{})
		request := discardRequestFor(prepared)
		assertDiscardFailure(
			t,
			executor.Discard(context.Background(), request),
			workercontracts.DiscardArtifactNotFound,
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
		assertDiscardFailure(
			t,
			executor.Discard(context.Background(), discardRequestFor(prepared)),
			workercontracts.DiscardArtifactNotFound,
		)
	})

	t.Run("published", func(t *testing.T) {
		store, staged := newStagedStore(t)
		if _, _, err := store.MarkPublished(
			staged.ExecutionID,
			staged.ArtifactID,
			staged.Staged.Fingerprint,
			joinstate.PublishedArtifact{
				RootID: staged.Specification.RootID,
				PathComponents: []string{
					"Movie.Release",
					"published.mkv",
				},
			},
			testTime().Add(time.Minute),
		); err != nil {
			t.Fatal(err)
		}
		executor := newExecutor(t, store, &fakeArtifacts{})
		assertDiscardFailure(
			t,
			executor.Discard(context.Background(), discardRequest(staged)),
			workercontracts.DiscardArtifactPublished,
		)
	})
}

func TestDiscardMapsFilesystemFailures(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		err    error
		reason workercontracts.DiscardFailureReason
	}{
		{
			name:   "fingerprint changed",
			err:    &mediafile.Failure{Kind: mediafile.FailureFingerprintMismatch},
			reason: workercontracts.DiscardArtifactFingerprintMismatch,
		},
		{
			name:   "discard failed",
			err:    &mediafile.Failure{Kind: mediafile.FailureFileUnavailable},
			reason: workercontracts.DiscardErrorReason,
		},
		{
			name:   "internal failure",
			err:    errors.New("unexpected failure"),
			reason: workercontracts.DiscardInternalError,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			store, staged := newStagedStore(t)
			executor := newExecutor(
				t,
				store,
				&fakeArtifacts{removeErr: test.err},
			)
			assertDiscardFailure(
				t,
				executor.Discard(context.Background(), discardRequest(staged)),
				test.reason,
			)
		})
	}
}

func TestDiscardRecoversAfterStateWriteFailure(t *testing.T) {
	t.Parallel()

	store, staged := newStagedStore(t)
	failingStore := &failingDiscardStore{Store: store, failOnce: true}
	artifacts := &fakeArtifacts{removed: true}
	executor := newExecutor(t, failingStore, artifacts)
	request := discardRequest(staged)

	assertDiscardFailure(
		t,
		executor.Discard(context.Background(), request),
		workercontracts.DiscardInternalError,
	)
	artifacts.removed = false
	response := executor.Discard(context.Background(), request)
	assertDiscardSuccess(t, response, request.RequestID, staged)
	if len(artifacts.removeCalls) != 2 {
		t.Fatalf("discard calls = %d, want 2", len(artifacts.removeCalls))
	}
}

type failingDiscardStore struct {
	*joinstate.Store
	failOnce bool
}

func (store *failingDiscardStore) MarkDiscarded(
	executionID string,
	artifactID string,
	fingerprint string,
	updatedAt time.Time,
) (joinstate.Execution, bool, error) {
	if store.failOnce {
		store.failOnce = false
		return joinstate.Execution{}, false, errors.New("write interrupted")
	}
	return store.Store.MarkDiscarded(executionID, artifactID, fingerprint, updatedAt)
}

func discardRequest(execution joinstate.Execution) workercontracts.DiscardRequestV1 {
	request := discardRequestFor(execution)
	request.ArtifactFingerprint = execution.Staged.Fingerprint
	return request
}

func discardRequestFor(execution joinstate.Execution) workercontracts.DiscardRequestV1 {
	return workercontracts.DiscardRequestV1{
		ArtifactFingerprint: "sha256:4444444444444444444444444444444444444444444444444444444444444444",
		ArtifactID:          execution.ArtifactID,
		Operation:           workercontracts.DiscardV1,
		RequestID:           "request:discard:test",
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	}
}

func assertDiscardSuccess(
	t *testing.T,
	response workercontracts.DiscardResponseV1,
	requestID string,
	execution joinstate.Execution,
) {
	t.Helper()
	if response.Kind != workercontracts.ProbeResponseSucceeded || response.Success == nil ||
		response.Success.RequestID != requestID ||
		response.Success.ArtifactID != execution.ArtifactID ||
		response.Success.ArtifactFingerprint != execution.Staged.Fingerprint {
		t.Fatalf("discard response = %#v", response)
	}
	if _, err := workercontracts.EncodeDiscardResponse(response); err != nil {
		t.Fatalf("encode discard response: %v", err)
	}
}

func assertDiscardFailure(
	t *testing.T,
	response workercontracts.DiscardResponseV1,
	reason workercontracts.DiscardFailureReason,
) {
	t.Helper()
	if response.Kind != workercontracts.ProbeResponseFailed || response.Failure == nil ||
		response.Failure.Reason != reason {
		t.Fatalf("discard response = %#v", response)
	}
	if _, err := workercontracts.EncodeDiscardResponse(response); err != nil {
		t.Fatalf("encode discard response: %v", err)
	}
}

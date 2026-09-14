package joinexecution

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/joinverification"
	"github.com/booxter/nix-config/radarr-repair/internal/workerclient"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const testArtifactFingerprint = "sha256:4444444444444444444444444444444444444444444444444444444444444444"

func TestExecutorPublishesAcceptedJoin(t *testing.T) {
	t.Parallel()

	store := &fakeStore{}
	worker := successfulWorker()
	executor := newTestExecutor(t, store, worker)
	execution, err := executor.Execute(context.Background(), testAuthorization(), testPaths())
	if err != nil {
		t.Fatal(err)
	}
	if execution.State != casestore.JoinPublished || execution.Published == nil ||
		execution.Published.RootID != "root:downloads" {
		t.Fatalf("execution = %#v", execution)
	}
	if worker.stageCalls != 1 || worker.publishCalls != 1 || worker.discardCalls != 0 {
		t.Fatalf(
			"worker calls: stage = %d, publish = %d, discard = %d",
			worker.stageCalls,
			worker.publishCalls,
			worker.discardCalls,
		)
	}
}

func TestExecutorDiscardsRejectedJoin(t *testing.T) {
	t.Parallel()

	store := &fakeStore{rejectStage: true}
	worker := successfulWorker()
	executor := newTestExecutor(t, store, worker)
	execution, err := executor.Execute(context.Background(), testAuthorization(), testPaths())
	if err != nil {
		t.Fatal(err)
	}
	if execution.State != casestore.JoinDiscarded {
		t.Fatalf("execution = %#v", execution)
	}
	if worker.stageCalls != 1 || worker.publishCalls != 0 || worker.discardCalls != 1 {
		t.Fatalf(
			"worker calls: stage = %d, publish = %d, discard = %d",
			worker.stageCalls,
			worker.publishCalls,
			worker.discardCalls,
		)
	}
}

func TestExecutorResumesAfterUncertainWorkerCalls(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name             string
		configure        func(*fakeWorker)
		wantFirstState   casestore.JoinExecutionState
		wantStageCalls   int
		wantPublishCalls int
	}{
		{
			name: "stage",
			configure: func(worker *fakeWorker) {
				worker.stageErr = errors.New("connection closed")
			},
			wantFirstState:   casestore.JoinPrepared,
			wantStageCalls:   2,
			wantPublishCalls: 1,
		},
		{
			name: "publish",
			configure: func(worker *fakeWorker) {
				worker.publishErr = errors.New("connection closed")
			},
			wantFirstState:   casestore.JoinArtifactReady,
			wantStageCalls:   1,
			wantPublishCalls: 2,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			store := &fakeStore{}
			worker := successfulWorker()
			test.configure(worker)
			executor := newTestExecutor(t, store, worker)

			first, err := executor.Execute(
				context.Background(),
				testAuthorization(),
				testPaths(),
			)
			if err == nil || !strings.Contains(err.Error(), "connection closed") ||
				first.State != test.wantFirstState {
				t.Fatalf("first execution = %#v, error = %v", first, err)
			}
			resumed, err := executor.Execute(
				context.Background(),
				testAuthorization(),
				testPaths(),
			)
			if err != nil || resumed.State != casestore.JoinPublished {
				t.Fatalf("resumed execution = %#v, error = %v", resumed, err)
			}
			if worker.stageCalls != test.wantStageCalls ||
				worker.publishCalls != test.wantPublishCalls {
				t.Fatalf(
					"worker calls: stage = %d, publish = %d",
					worker.stageCalls,
					worker.publishCalls,
				)
			}
		})
	}
}

func TestExecutorLeavesWorkerFailureTerminal(t *testing.T) {
	t.Parallel()

	store := &fakeStore{}
	worker := successfulWorker()
	worker.stageResponse = workercontracts.StageJoinResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.StageJoinFailureResponseV1{
			Operation: workercontracts.StageJoinV1,
			Reason:    workercontracts.StageJoinJoinError,
		},
	}
	executor := newTestExecutor(t, store, worker)
	execution, err := executor.Execute(context.Background(), testAuthorization(), testPaths())
	if err != nil {
		t.Fatal(err)
	}
	if execution.State != casestore.JoinFailed || execution.Failure == nil ||
		execution.Failure.Reason != string(workercontracts.StageJoinJoinError) {
		t.Fatalf("execution = %#v", execution)
	}
	if worker.stageCalls != 1 || worker.publishCalls != 0 || worker.discardCalls != 0 {
		t.Fatalf(
			"worker calls: stage = %d, publish = %d, discard = %d",
			worker.stageCalls,
			worker.publishCalls,
			worker.discardCalls,
		)
	}

	repeated, err := executor.Execute(context.Background(), testAuthorization(), testPaths())
	if err != nil || repeated.State != casestore.JoinFailed || worker.stageCalls != 1 {
		t.Fatalf("repeated execution = %#v, error = %v", repeated, err)
	}
}

func newTestExecutor(t *testing.T, store Store, worker Worker) *Executor {
	t.Helper()
	executor, err := New(Dependencies{
		Store: store, Worker: worker,
		Clock: fixedClock{now: time.Date(2026, time.September, 13, 23, 0, 0, 0, time.UTC)},
	})
	if err != nil {
		t.Fatal(err)
	}
	return executor
}

func testAuthorization() decisionpolicy.AuthorizedJoin {
	return decisionpolicy.AuthorizedJoin{
		CaseID:       "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		CapabilityID: "capability:join",
		OrderedParts: []decisionpolicy.AuthorizedJoinPart{
			{FileID: "file:first"},
			{FileID: "file:second"},
		},
	}
}

func testPaths() map[controller.FileID]string {
	return map[controller.FileID]string{
		"file:first":  "/downloads/Movie/Movie.CD1.mkv",
		"file:second": "/downloads/Movie/Movie.CD2.mkv",
	}
}

type fixedClock struct {
	now time.Time
}

func (clock fixedClock) Now() time.Time {
	return clock.now
}

type fakeWorker struct {
	stageResponse   workercontracts.StageJoinResponseV1
	publishResponse workercontracts.PublishResponseV1
	discardResponse workercontracts.DiscardResponseV1
	stageErr        error
	publishErr      error
	discardErr      error
	stageCalls      int
	publishCalls    int
	discardCalls    int
}

func successfulWorker() *fakeWorker {
	return &fakeWorker{
		stageResponse: workercontracts.StageJoinResponseV1{
			Kind: workercontracts.ProbeResponseSucceeded,
			Success: &workercontracts.StageJoinSuccessResponseV1{
				ArtifactID:          "artifact:join:01",
				ArtifactFingerprint: testArtifactFingerprint,
				SizeBytes:           299,
			},
		},
		publishResponse: workercontracts.PublishResponseV1{
			Kind: workercontracts.ProbeResponseSucceeded,
			Success: &workercontracts.PublishSuccessResponseV1{
				ArtifactID:          "artifact:join:01",
				ArtifactFingerprint: testArtifactFingerprint,
				RootID:              "root:downloads",
				PathComponents:      []string{"Movie", "radarr-repair-join.mkv"},
			},
		},
		discardResponse: workercontracts.DiscardResponseV1{
			Kind: workercontracts.ProbeResponseSucceeded,
			Success: &workercontracts.DiscardSuccessResponseV1{
				ArtifactID:          "artifact:join:01",
				ArtifactFingerprint: testArtifactFingerprint,
			},
		},
	}
}

func (worker *fakeWorker) StageJoin(
	_ context.Context,
	executionID string,
	_ decisionpolicy.AuthorizedJoin,
	_ map[controller.FileID]string,
) (workerclient.StageJoinExchange, error) {
	worker.stageCalls++
	if worker.stageErr != nil {
		err := worker.stageErr
		worker.stageErr = nil
		return workerclient.StageJoinExchange{}, err
	}
	return workerclient.StageJoinExchange{
		Request:  workercontracts.StageJoinRequestV1{ExecutionID: executionID},
		Response: worker.stageResponse,
	}, nil
}

func (worker *fakeWorker) PublishJoin(
	_ context.Context,
	_ workerclient.Artifact,
) (workercontracts.PublishResponseV1, error) {
	worker.publishCalls++
	if worker.publishErr != nil {
		err := worker.publishErr
		worker.publishErr = nil
		return workercontracts.PublishResponseV1{}, err
	}
	return worker.publishResponse, nil
}

func (worker *fakeWorker) DiscardJoin(
	_ context.Context,
	_ workerclient.Artifact,
) (workercontracts.DiscardResponseV1, error) {
	worker.discardCalls++
	if worker.discardErr != nil {
		err := worker.discardErr
		worker.discardErr = nil
		return workercontracts.DiscardResponseV1{}, err
	}
	return worker.discardResponse, nil
}

type fakeStore struct {
	execution   casestore.JoinExecution
	rejectStage bool
}

func (store *fakeStore) PrepareJoin(
	authorized decisionpolicy.AuthorizedJoin,
	preparedAt time.Time,
) (casestore.JoinExecution, bool, error) {
	if store.execution.State != "" {
		return store.execution, false, nil
	}
	store.execution = casestore.JoinExecution{
		Version:       casestore.JoinExecutionVersionV1,
		ExecutionID:   "execution:join:01",
		Authorization: authorized,
		State:         casestore.JoinPrepared,
		PreparedAt:    preparedAt,
		UpdatedAt:     preparedAt,
	}
	return store.execution, true, nil
}

func (store *fakeStore) RecordJoinStage(
	_ decisionpolicy.AuthorizedJoin,
	_ workercontracts.StageJoinRequestV1,
	response workercontracts.StageJoinResponseV1,
	updatedAt time.Time,
) (casestore.JoinExecution, bool, error) {
	store.execution.UpdatedAt = updatedAt
	store.execution.Stage = &casestore.JoinStage{Rejections: []joinverification.RejectionReason{}}
	if response.Kind == workercontracts.ProbeResponseFailed {
		store.execution.State = casestore.JoinFailed
		store.execution.Failure = &casestore.JoinFailure{
			Operation: string(workercontracts.StageJoinV1),
			Reason:    string(response.Failure.Reason),
		}
		return store.execution, true, nil
	}
	store.execution.Artifact = &casestore.JoinArtifact{
		ID: response.Success.ArtifactID, Fingerprint: response.Success.ArtifactFingerprint,
		SizeBytes: response.Success.SizeBytes,
	}
	if store.rejectStage {
		store.execution.State = casestore.JoinDiscardPending
		store.execution.Stage.Rejections = []joinverification.RejectionReason{
			joinverification.DurationOutsideTolerance,
		}
	} else {
		store.execution.State = casestore.JoinArtifactReady
	}
	return store.execution, true, nil
}

func (store *fakeStore) RecordJoinPublish(
	_ string,
	response workercontracts.PublishResponseV1,
	updatedAt time.Time,
) (casestore.JoinExecution, bool, error) {
	store.execution.UpdatedAt = updatedAt
	if response.Kind == workercontracts.ProbeResponseFailed {
		store.execution.State = casestore.JoinFailed
		store.execution.Failure = &casestore.JoinFailure{
			Operation: string(workercontracts.PublishV1),
			Reason:    string(response.Failure.Reason),
		}
		return store.execution, true, nil
	}
	store.execution.State = casestore.JoinPublished
	store.execution.Published = &casestore.JoinPublishedArtifact{
		RootID: response.Success.RootID,
		PathComponents: append(
			[]string(nil),
			response.Success.PathComponents...,
		),
	}
	return store.execution, true, nil
}

func (store *fakeStore) RecordJoinDiscard(
	_ string,
	response workercontracts.DiscardResponseV1,
	updatedAt time.Time,
) (casestore.JoinExecution, bool, error) {
	store.execution.UpdatedAt = updatedAt
	if response.Kind == workercontracts.ProbeResponseFailed {
		store.execution.State = casestore.JoinFailed
		store.execution.Failure = &casestore.JoinFailure{
			Operation: string(workercontracts.DiscardV1),
			Reason:    string(response.Failure.Reason),
		}
		return store.execution, true, nil
	}
	store.execution.State = casestore.JoinDiscarded
	return store.execution, true, nil
}

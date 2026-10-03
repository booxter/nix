package repair

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

func TestRepairImportsAndKeepsUIStateCurrent(t *testing.T) {
	engine, adapter, job := fixture(t)
	ctx := context.Background()
	if err := engine.Run(ctx, job.ID); err != nil {
		t.Fatal(err)
	}
	assertState(t, engine, job.ID, jobs.Importing)
	attempt, err := engine.Store.LatestAttempt(ctx, job.ID)
	if err != nil {
		t.Fatal(err)
	}
	if attempt.CommandID != 12 || attempt.HistoryIDBefore != 7 || attempt.OutputPath != "/repaired/movie.mkv" {
		t.Fatalf("missing import recovery evidence: %+v", attempt)
	}
	adapter.status.Receipt = json.RawMessage(`{"file_id":42}`)
	if err := engine.Run(ctx, job.ID); err != nil {
		t.Fatal(err)
	}
	assertState(t, engine, job.ID, jobs.Imported)
	if err := engine.Run(ctx, job.ID); err != nil {
		t.Fatal(err)
	}
	if adapter.repairs != 1 || adapter.submissions != 1 {
		t.Fatal("repeated completed repair")
	}
}

func TestUncertainSubmissionIsReconciledAfterRestartWithoutResubmission(t *testing.T) {
	engine, adapter, job := fixture(t)
	ctx := context.Background()
	adapter.submitError = errors.New("connection lost after POST")
	if err := engine.Run(ctx, job.ID); err == nil {
		t.Fatal("lost submission error")
	}
	assertState(t, engine, job.ID, jobs.Importing)
	// A new engine has no in-memory knowledge of whether POST reached Servarr.
	restarted := &Engine{Store: engine.Store, Adapter: adapter, Now: engine.Now}
	if err := restarted.Run(ctx, job.ID); err != nil {
		t.Fatal(err)
	}
	assertState(t, engine, job.ID, jobs.Importing)
	adapter.status.Receipt = json.RawMessage(`{"file_id":42}`)
	if err := restarted.Run(ctx, job.ID); err != nil {
		t.Fatal(err)
	}
	assertState(t, engine, job.ID, jobs.Imported)
	if adapter.submissions != 1 {
		t.Fatal("repeated uncertain POST")
	}
}

func TestInterruptedRepairDoesNotImportPartialOutput(t *testing.T) {
	engine, adapter, job := fixture(t)
	ctx := context.Background()
	if _, err := engine.Store.Start(ctx, job.ID, engine.Now()); err != nil {
		t.Fatal(err)
	}
	if err := engine.Run(ctx, job.ID); err != nil {
		t.Fatal(err)
	}
	assertState(t, engine, job.ID, jobs.Failed)
	if adapter.repairs != 0 || adapter.submissions != 0 {
		t.Fatal("used interrupted output")
	}
}

func TestRepairRejectionAndFailureNeverSubmitImports(t *testing.T) {
	for _, test := range []struct {
		name    string
		failure error
		state   jobs.State
	}{
		{"incompatible sources", &BlockedError{Reason: "mixed time bases"}, jobs.Blocked},
		{"media command failed", errors.New("ffmpeg failed"), jobs.Failed},
	} {
		t.Run(test.name, func(t *testing.T) {
			engine, adapter, job := fixture(t)
			adapter.repairError = test.failure
			if err := engine.Run(context.Background(), job.ID); !errors.Is(err, test.failure) {
				t.Fatalf("error: %v", err)
			}
			assertState(t, engine, job.ID, test.state)
			if adapter.submissions != 0 {
				t.Fatal("imported rejected output")
			}
		})
	}
}

func TestHistoryOutageDoesNotMakeImportRetryable(t *testing.T) {
	engine, adapter, job := fixture(t)
	ctx := context.Background()
	adapter.checkError = errors.New("history unavailable")
	if err := engine.Run(ctx, job.ID); err == nil {
		t.Fatal("lost history error")
	}
	assertState(t, engine, job.ID, jobs.Importing)
	if err := engine.Store.SetPlan(ctx, job.ID, job.SourceFingerprint, job.Plan, "retry", engine.Now()); !errors.Is(err, jobs.ErrConflict) {
		t.Fatalf("uncertain import became retryable: %v", err)
	}
	adapter.checkError = nil
	adapter.status.Failure = "command completed without importing the selected files"
	if err := engine.Run(ctx, job.ID); err != nil {
		t.Fatal(err)
	}
	assertState(t, engine, job.ID, jobs.Importing)

	later := engine.Now().Add(time.Minute)
	engine.Now = func() time.Time { return later }
	if err := engine.Run(ctx, job.ID); err != nil {
		t.Fatal(err)
	}
	assertState(t, engine, job.ID, jobs.Failed)
}

type fakeAdapter struct {
	store                                *jobs.Store
	jobID                                int64
	repairs, submissions                 int
	repairError, submitError, checkError error
	status                               ImportStatus
}

func (adapter *fakeAdapter) Repair(_ context.Context, _ jobs.Job, _ jobs.Attempt) (PreparedImport, error) {
	adapter.repairs++
	return PreparedImport{OutputPath: "/repaired/movie.mkv", Request: json.RawMessage(`{"path":"/repaired/movie.mkv"}`), HistoryIDBefore: 7}, adapter.repairError
}

func (adapter *fakeAdapter) Submit(ctx context.Context, request json.RawMessage) (int64, error) {
	job, err := adapter.store.Get(ctx, adapter.jobID)
	if err != nil {
		return 0, err
	}
	attempt, err := adapter.store.LatestAttempt(ctx, job.ID)
	if err != nil {
		return 0, err
	}
	if job.State != jobs.Importing || string(attempt.ImportRequest) != string(request) {
		return 0, errors.New("submission preceded durable import intent")
	}
	adapter.submissions++
	return 12, adapter.submitError
}

func (adapter *fakeAdapter) CheckImport(_ context.Context, _ jobs.Attempt) (ImportStatus, error) {
	return adapter.status, adapter.checkError
}

func fixture(t *testing.T) (*Engine, *fakeAdapter, jobs.Job) {
	t.Helper()
	store, err := jobs.Open(filepath.Join(t.TempDir(), "jobs.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := store.Close(); err != nil {
			t.Error(err)
		}
	})
	ctx := context.Background()
	job, err := store.Observe(ctx, jobs.Job{Service: jobs.Radarr, QueueID: 42, SourceFingerprint: "source"})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetPlan(ctx, job.ID, job.SourceFingerprint, json.RawMessage(`{"action":"join"}`), "", time.Now()); err != nil {
		t.Fatal(err)
	}
	adapter := &fakeAdapter{store: store, jobID: job.ID}
	return &Engine{Store: store, Adapter: adapter, Now: time.Now}, adapter, job
}

func assertState(t *testing.T, engine *Engine, id int64, state jobs.State) {
	t.Helper()
	ctx := context.Background()
	job, err := engine.Store.Get(ctx, id)
	if err != nil || job.State != state {
		t.Fatalf("job: %+v, %v; want %s", job, err, state)
	}
	attempt, err := engine.Store.LatestAttempt(ctx, id)
	if err != nil || attempt.State != state {
		t.Fatalf("attempt: %+v, %v; want %s", attempt, err, state)
	}
}

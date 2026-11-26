package repair

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
)

func TestFailedAttemptRecordsItsErrorInTrace(t *testing.T) {
	engine, adapter, job := fixture(t)
	recorder := tracetest.NewSpanRecorder()
	provider := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder))
	defer provider.Shutdown(context.Background())
	engine.Tracer = provider.Tracer("test")
	adapter.prepareError = context.DeadlineExceeded
	if err := engine.Run(context.Background(), job.ID); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error: %v", err)
	}
	spans := recorder.Ended()
	if len(spans) != 1 {
		t.Fatalf("attempt spans: got %d, want 1", len(spans))
	}
	if spans[0].Status().Code != codes.Error {
		t.Fatalf("attempt status: %v", spans[0].Status())
	}
	if len(spans[0].Events()) != 1 {
		t.Fatalf("exception events: %v", spans[0].Events())
	}
	if spans[0].EndTime().Before(spans[0].StartTime()) {
		t.Fatal("invalid attempt duration")
	}
}

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
	// Servarr can remove the queue entry before Repairr sees import history.
	if err := engine.Store.ReconcileQueue(ctx, job.Service, nil, engine.Now()); err != nil {
		t.Fatal(err)
	}
	service := &waitingService{fakeAdapter: *adapter}
	restarted := Scheduler{
		Store: engine.Store, Name: job.Service, Service: service, Now: engine.Now,
		Disabled: func() (bool, error) { return true, nil },
	}
	if err := restarted.advance(ctx); err != nil {
		t.Fatal(err)
	}
	assertState(t, engine, job.ID, jobs.Importing)
	service.status.Receipt = json.RawMessage(`{"file_id":42}`)
	if err := restarted.advance(ctx); err != nil {
		t.Fatal(err)
	}
	assertState(t, engine, job.ID, jobs.Imported)
	if service.submissions != 1 {
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
		name           string
		authorizeError error
		prepareError   error
		state          jobs.State
	}{
		{name: "incompatible sources", authorizeError: &BlockedError{Reason: "mixed time bases"}, state: jobs.Blocked},
		{name: "media command failed", prepareError: errors.New("ffmpeg failed"), state: jobs.Failed},
	} {
		t.Run(test.name, func(t *testing.T) {
			engine, adapter, job := fixture(t)
			adapter.authorizeError = test.authorizeError
			adapter.prepareError = test.prepareError
			if err := engine.Run(context.Background(), job.ID); err == nil {
				t.Fatal("expected the attempt to stop")
			}
			assertState(t, engine, job.ID, test.state)
			if test.authorizeError != nil && adapter.repairs != 0 {
				t.Fatal("prepared media for a rejected plan")
			}
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
	planned, err := engine.Store.Get(ctx, job.ID)
	if err != nil {
		t.Fatal(err)
	}
	planned.State = jobs.Ready
	planned.UpdatedAt = engine.Now()
	if err := engine.Store.FinishPlanning(ctx, planned); !errors.Is(err, jobs.ErrConflict) {
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
	store       *jobs.Store
	jobID       int64
	repairs     int
	submissions int
	status      ImportStatus

	authorizeError error
	prepareError   error
	submitError    error
	checkError     error
}

func (adapter *fakeAdapter) ImportSteps() ImportFlow {
	return ImportSteps[string]{Authorize: adapter.authorize, PrepareImport: adapter.prepareImport}
}

func (adapter *fakeAdapter) authorize(context.Context, jobs.Job, json.RawMessage) (string, error) {
	return "/repaired/movie.mkv", adapter.authorizeError
}

func (adapter *fakeAdapter) prepareImport(_ context.Context, _ jobs.Attempt, path string) (PreparedImport, error) {
	adapter.repairs++
	return PreparedImport{OutputPath: path, Request: json.RawMessage(`{"path":"/repaired/movie.mkv"}`), HistoryIDBefore: 7}, adapter.prepareError
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
	store, err := jobs.Open(filepath.Join(t.TempDir(), "jobs.db"), testInputs)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := store.Close(); err != nil {
			t.Error(err)
		}
	})
	ctx := context.Background()
	job, err := store.Observe(ctx, jobs.Job{Service: jobs.Radarr, QueueID: 42, SourceFingerprint: "source", Evidence: json.RawMessage(`{"files":"source"}`)})
	if err != nil {
		t.Fatal(err)
	}
	job.State = jobs.Ready
	job.Plan = json.RawMessage(`{"action":"join"}`)
	job.UpdatedAt = time.Now()
	if err := store.FinishPlanning(ctx, job); err != nil {
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

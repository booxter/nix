package jobs

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestAttemptsSurviveRestartAndKeepJobStateInSync(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "jobs.db")
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	at := time.Now().UTC()
	job, err := store.Observe(ctx, Job{Service: Radarr, QueueID: 42, DownloadID: "download", Title: "Movie",
		SourceFingerprint: "original", Evidence: json.RawMessage(`{"files":["part1","part2"]}`), UpdatedAt: at})
	if err != nil {
		t.Fatal(err)
	}
	plan := json.RawMessage(`{"action":"join","files":["part1","part2"]}`)
	if err := store.SetPlan(ctx, job.ID, job.SourceFingerprint, plan, "", at); err != nil {
		t.Fatal(err)
	}
	attempt, err := store.Start(ctx, job.ID, at)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Start(ctx, job.ID, at); !errors.Is(err, ErrConflict) {
		t.Fatalf("duplicate start: %v", err)
	}
	attempt.State, attempt.Reason = Blocked, "incompatible source time bases"
	if err := store.UpdateAttempt(ctx, attempt); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	job, err = store.Get(ctx, job.ID)
	if err != nil || job.State != Blocked || job.Reason != attempt.Reason {
		t.Fatalf("job=%+v error=%v", job, err)
	}
	if err := store.SetPlan(ctx, job.ID, job.SourceFingerprint, plan, "retry", at); err != nil {
		t.Fatal(err)
	}
	retry, err := store.Start(ctx, job.ID, at)
	if err != nil || retry.Number != 2 {
		t.Fatalf("retry=%+v error=%v", retry, err)
	}
	if err := store.UpdateAttempt(ctx, attempt); !errors.Is(err, ErrConflict) {
		t.Fatalf("old attempt changed job: %v", err)
	}
	retry.State = Importing
	retry.OutputPath = "/downloads/repaired.mkv"
	if err := store.UpdateAttempt(ctx, retry); err != nil {
		t.Fatal(err)
	}
	retry.State = Imported
	retry.ImportReceipt = json.RawMessage(`{"movie_file_id":9}`)
	if err := store.UpdateAttempt(ctx, retry); err != nil {
		t.Fatal(err)
	}
	job, err = store.Observe(ctx, job)
	if err != nil || job.State != Imported {
		t.Fatalf("observation reset imported job: %+v %v", job, err)
	}
	attempts, err := store.Attempts(ctx, job.ID)
	if err != nil || len(attempts) != 2 || attempts[1].State != Imported || string(attempts[1].ImportReceipt) != `{"movie_file_id":9}` {
		t.Fatalf("attempts=%+v error=%v", attempts, err)
	}
}

func TestChangedSourcesInvalidateUnusedPlans(t *testing.T) {
	ctx := context.Background()
	store, err := Open(filepath.Join(t.TempDir(), "jobs.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	job, err := store.Observe(ctx, Job{Service: Lidarr, QueueID: 1, DownloadID: "album", Title: "Album",
		SourceFingerprint: "first", Evidence: json.RawMessage(`{}`), UpdatedAt: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetPlan(ctx, job.ID, "first", json.RawMessage(`{"action":"import"}`), "", job.UpdatedAt); err != nil {
		t.Fatal(err)
	}
	job.SourceFingerprint = "second"
	job, err = store.Observe(ctx, job)
	if err != nil || job.State != Observed || len(job.Plan) != 0 {
		t.Fatalf("changed job=%+v error=%v", job, err)
	}
	if err := store.SetPlan(ctx, job.ID, "first", json.RawMessage(`{}`), "", job.UpdatedAt); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale plan accepted: %v", err)
	}
}

func TestQueueIdentityIncludesServiceAndEmptyDownloadID(t *testing.T) {
	ctx := context.Background()
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	at := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	identities := []Job{
		{Service: Radarr, QueueID: 42, DownloadID: "download"},
		{Service: Radarr, QueueID: 42},
		{Service: Lidarr, QueueID: 42, DownloadID: "download"},
	}
	ids := make(map[int64]bool)
	for _, identity := range identities {
		identity.UpdatedAt = at
		job, err := store.Observe(ctx, identity)
		if err != nil {
			t.Fatal(err)
		}
		if ids[job.ID] {
			t.Fatalf("different queue identities share job %d", job.ID)
		}
		ids[job.ID] = true
		identity.Title = "updated title"
		updated, err := store.Observe(ctx, identity)
		if err != nil || updated.ID != job.ID || updated.Title != identity.Title {
			t.Fatalf("repeated observation: %+v, %v", updated, err)
		}
		stored, err := store.Get(ctx, job.ID)
		if err != nil || !stored.UpdatedAt.Equal(at) {
			t.Fatalf("observation time changed: %+v, %v", stored, err)
		}
	}
	listed, err := store.List(ctx, Radarr)
	if err != nil || len(listed) != 2 {
		t.Fatalf("Radarr jobs: %+v, %v", listed, err)
	}
}

func TestObservationPreservesActiveAttemptEvidence(t *testing.T) {
	ctx := context.Background()
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	job, err := store.Observe(ctx, Job{Service: Radarr, QueueID: 42,
		SourceFingerprint: "first", Evidence: json.RawMessage(`{"source":"first"}`)})
	if err != nil {
		t.Fatal(err)
	}
	plan := json.RawMessage(`{"action":"join"}`)
	if err := store.SetPlan(ctx, job.ID, "first", plan, "", time.Now()); err != nil {
		t.Fatal(err)
	}
	attempt, err := store.Start(ctx, job.ID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	job.SourceFingerprint, job.Evidence = "second", json.RawMessage(`{"source":"second"}`)
	observed, err := store.Observe(ctx, job)
	if err != nil || observed.State != Running || observed.SourceFingerprint != "first" || string(observed.Evidence) != `{"source":"first"}` {
		t.Fatalf("active evidence changed: %+v, %v", observed, err)
	}
	if err := store.SetPlan(ctx, job.ID, "first", plan, "", time.Now()); !errors.Is(err, ErrConflict) {
		t.Fatalf("replaced an active plan: %v", err)
	}
	attempt.State = Failed
	if err := store.UpdateAttempt(ctx, attempt); err != nil {
		t.Fatal(err)
	}
	observed, err = store.Observe(ctx, job)
	if err != nil || observed.State != Observed || observed.SourceFingerprint != "second" || observed.Plan != nil {
		t.Fatalf("new source not observed after failure: %+v, %v", observed, err)
	}
}

func TestConcurrentStartCreatesOneAttempt(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "jobs.db")
	first, second := openStore(t, path), openStore(t, path)
	job, err := first.Observe(ctx, Job{Service: Lidarr, QueueID: 1})
	if err != nil {
		t.Fatal(err)
	}
	if err := first.SetPlan(ctx, job.ID, "", json.RawMessage(`{}`), "", time.Now()); err != nil {
		t.Fatal(err)
	}
	start := make(chan struct{})
	results := make(chan error, 2)
	var workers sync.WaitGroup
	for _, store := range []*Store{first, second} {
		workers.Go(func() {
			<-start
			_, err := store.Start(ctx, job.ID, time.Now())
			results <- err
		})
	}
	close(start)
	workers.Wait()
	close(results)
	succeeded, conflicted := 0, 0
	for err := range results {
		switch {
		case err == nil:
			succeeded++
		case errors.Is(err, ErrConflict):
			conflicted++
		default:
			t.Fatal(err)
		}
	}
	if succeeded != 1 || conflicted != 1 {
		t.Fatalf("successful starts: %d; conflicts: %d", succeeded, conflicted)
	}
	attempts, err := first.Attempts(ctx, job.ID)
	if err != nil || len(attempts) != 1 {
		t.Fatalf("attempts: %+v, %v", attempts, err)
	}
}

func TestFailedWriteDoesNotAdvanceJob(t *testing.T) {
	ctx := context.Background()
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	job, err := store.Observe(ctx, Job{Service: Lidarr, QueueID: 1})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetPlan(ctx, job.ID, "", json.RawMessage(`{}`), "", time.Now()); err != nil {
		t.Fatal(err)
	}
	attempt, err := store.Start(ctx, job.ID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	attempt.State, attempt.ImportReceipt = Imported, json.RawMessage(`invalid JSON`)
	if err := store.UpdateAttempt(ctx, attempt); err == nil {
		t.Fatal("saved an invalid import receipt")
	}
	job, err = store.Get(ctx, job.ID)
	if err != nil || job.State != Running {
		t.Fatalf("failed write changed job: %+v, %v", job, err)
	}
	attempts, err := store.Attempts(ctx, job.ID)
	if err != nil || len(attempts) != 1 || attempts[0].State != Running || len(attempts[0].ImportReceipt) != 0 {
		t.Fatalf("failed write changed attempt: %+v, %v", attempts, err)
	}
}

func openStore(t *testing.T, path string) *Store {
	t.Helper()
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := store.Close(); err != nil {
			t.Error(err)
		}
	})
	return store
}

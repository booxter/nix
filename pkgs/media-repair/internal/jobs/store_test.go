package jobs

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

func TestAttemptsSurviveRestartAndKeepJobStateInSync(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "jobs.db")
	store, err := Open(path, testInputs)
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
	if err := finishTestPlan(ctx, store, job.ID, job.SourceFingerprint, plan, at); err != nil {
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
	attempt.Outcome = OutcomeRuntimeMismatch
	if err := store.UpdateAttempt(ctx, attempt); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(path, testInputs)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	job, err = store.Get(ctx, job.ID)
	if err != nil || job.State != Blocked || job.Reason != attempt.Reason || job.Outcome != attempt.Outcome {
		t.Fatalf("job=%+v error=%v", job, err)
	}
	if err := store.RequestReconsideration(ctx, job, planning.Answer{Guidance: "retry"}, at); err != nil {
		t.Fatal(err)
	}
	job, err = store.Get(ctx, job.ID)
	if err != nil || job.Outcome != "" {
		t.Fatalf("outcome after reconsideration = %q, error = %v", job.Outcome, err)
	}
	if err := finishTestPlan(ctx, store, job.ID, job.SourceFingerprint, plan, at); err != nil {
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
	retry.ImportReceipt = &servarr.ImportReceipt{Files: []servarr.ImportedFile{{MovieFileID: 9}}}
	if err := store.UpdateAttempt(ctx, retry); err != nil {
		t.Fatal(err)
	}
	job, err = store.Observe(ctx, job)
	if err != nil || job.State != Imported {
		t.Fatalf("observation reset imported job: %+v %v", job, err)
	}
	attempts, err := store.Attempts(ctx, job.ID)
	if err != nil || len(attempts) != 2 || attempts[1].State != Imported || !reflect.DeepEqual(attempts[1].ImportReceipt, retry.ImportReceipt) {
		t.Fatalf("attempts=%+v error=%v", attempts, err)
	}
}

func TestReadPreviouslySavedImportReceipts(t *testing.T) {
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	at := time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		service Service
		saved   string
		files   []servarr.ImportedFile
	}{
		{
			Radarr, `{"HistoryID":51,"MovieID":42,"MovieFileID":8,"DownloadID":"movie",
				"DroppedPath":"/downloads/m.mkv","ImportedPath":"/movies/m.mkv","OccurredAt":"2026-11-01T09:00:00Z"}`,
			[]servarr.ImportedFile{{HistoryID: 51, MovieID: 42, MovieFileID: 8, DownloadID: "movie",
				DroppedPath: "/downloads/m.mkv", ImportedPath: "/movies/m.mkv", OccurredAt: at}},
		},
		{
			Lidarr, `[
				{"history_id":91,"artist_id":7,"album_id":3,"track_id":12,"download_id":"album",
				 "dropped_path":"/d/1.flac","imported_path":"/music/1.flac","occurred_at":"2026-11-01T09:00:00Z"},
				{"history_id":92,"artist_id":7,"album_id":3,"track_id":11,"download_id":"album",
				 "dropped_path":"/d/2.flac","imported_path":"/music/2.flac","occurred_at":"2026-11-01T09:00:00Z"}
			]`,
			[]servarr.ImportedFile{
				{HistoryID: 91, ArtistID: 7, AlbumID: 3, TrackID: 12, DownloadID: "album",
					DroppedPath: "/d/1.flac", ImportedPath: "/music/1.flac", OccurredAt: at},
				{HistoryID: 92, ArtistID: 7, AlbumID: 3, TrackID: 11, DownloadID: "album",
					DroppedPath: "/d/2.flac", ImportedPath: "/music/2.flac", OccurredAt: at},
			},
		},
	} {
		t.Run(string(test.service), func(t *testing.T) {
			ctx := context.Background()
			job, err := store.Observe(ctx, Job{Service: test.service, QueueID: 42})
			if err != nil {
				t.Fatal(err)
			}
			// Seed the bytes written by the old daemon, bypassing the current encoder.
			if err := store.db.Exec("INSERT INTO attempts (job_id, number, state, import_receipt) VALUES (?, 1, ?, ?)",
				job.ID, Imported, test.saved).Error; err != nil {
				t.Fatal(err)
			}
			_, attempts, err := store.JobWithAttempts(ctx, job.ID)
			if err != nil {
				t.Fatal(err)
			}
			want := &servarr.ImportReceipt{Files: test.files}
			if len(attempts) != 1 || !reflect.DeepEqual(attempts[0].ImportReceipt, want) {
				t.Fatalf("saved receipt changed: attempts=%+v, want %+v", attempts, want)
			}
		})
	}
}

func TestChangedSourcesInvalidateUnusedPlans(t *testing.T) {
	ctx := context.Background()
	store, err := Open(filepath.Join(t.TempDir(), "jobs.db"), testInputs)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	job, err := store.Observe(ctx, Job{Service: Lidarr, QueueID: 1, DownloadID: "album", Title: "Album",
		SourceFingerprint: "first", Evidence: json.RawMessage(`{"source":"first"}`), UpdatedAt: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	if err := finishTestPlan(ctx, store, job.ID, "first", json.RawMessage(`{"action":"import"}`), job.UpdatedAt); err != nil {
		t.Fatal(err)
	}
	job.SourceFingerprint = "second"
	job.Evidence = json.RawMessage(`{"source":"second"}`)
	job, err = store.Observe(ctx, job)
	if err != nil || job.State != Observed || len(job.Plan) != 0 {
		t.Fatalf("changed job=%+v error=%v", job, err)
	}
	if err := finishTestPlan(ctx, store, job.ID, "first", json.RawMessage(`{}`), job.UpdatedAt); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale plan accepted: %v", err)
	}
}

func TestInspectionFindingsHoldAReadyPlanUntilTheDownloadIsReadyAgain(t *testing.T) {
	ctx := context.Background()
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	at := time.Now().UTC()
	album := Job{Service: Lidarr, QueueID: 42, DownloadID: "album", UpdatedAt: at}
	ready := album
	ready.SourceFingerprint = "original"
	ready.Evidence = json.RawMessage(`{"source":"original"}`)
	saved, err := store.Observe(ctx, ready)
	if err != nil {
		t.Fatal(err)
	}
	if err := finishTestPlan(ctx, store, saved.ID, ready.SourceFingerprint, json.RawMessage(`{"action":"import"}`), at); err != nil {
		t.Fatal(err)
	}

	album.Findings = []string{"incomplete_download"}
	if _, err := store.Observe(ctx, album); err != nil {
		t.Fatal(err)
	}
	due, err := store.DueRepairs(ctx, Lidarr, at)
	if err != nil || len(due) != 0 {
		t.Fatalf("incomplete download was scheduled: %v, %v", due, err)
	}

	if _, err := store.Observe(ctx, ready); err != nil {
		t.Fatal(err)
	}
	due, err = store.DueRepairs(ctx, Lidarr, at)
	if err != nil || len(due) != 1 || due[0].ID != saved.ID || due[0].State != Ready {
		t.Fatalf("ready plan did not resume: %v, %v", due, err)
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
	if err := finishTestPlan(ctx, store, job.ID, "first", plan, time.Now()); err != nil {
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
	if err := finishTestPlan(ctx, store, job.ID, "first", plan, time.Now()); !errors.Is(err, ErrConflict) {
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
	job, err := first.Observe(ctx, Job{Service: Lidarr, QueueID: 1, Evidence: json.RawMessage(`{"source":"album"}`)})
	if err != nil {
		t.Fatal(err)
	}
	if err := finishTestPlan(ctx, first, job.ID, "", json.RawMessage(`{}`), time.Now()); err != nil {
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
	job, err := store.Observe(ctx, Job{Service: Lidarr, QueueID: 1, Evidence: json.RawMessage(`{"source":"album"}`)})
	if err != nil {
		t.Fatal(err)
	}
	if err := finishTestPlan(ctx, store, job.ID, "", json.RawMessage(`{}`), time.Now()); err != nil {
		t.Fatal(err)
	}
	attempt, err := store.Start(ctx, job.ID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	attempt.State, attempt.ImportRequest = Importing, json.RawMessage(`invalid JSON`)
	if err := store.UpdateAttempt(ctx, attempt); err == nil {
		t.Fatal("saved an invalid import request")
	}
	job, err = store.Get(ctx, job.ID)
	if err != nil || job.State != Running {
		t.Fatalf("failed write changed job: %+v, %v", job, err)
	}
	attempts, err := store.Attempts(ctx, job.ID)
	if err != nil || len(attempts) != 1 || attempts[0].State != Running || len(attempts[0].ImportRequest) != 0 {
		t.Fatalf("failed write changed attempt: %+v, %v", attempts, err)
	}
}

func finishTestPlan(ctx context.Context, store *Store, id int64, fingerprint string, plan json.RawMessage, at time.Time) error {
	job, err := store.Get(ctx, id)
	if err != nil {
		return err
	}
	job.SourceFingerprint = fingerprint
	job.State = Ready
	job.Plan = plan
	job.UpdatedAt = at
	return store.FinishPlanning(ctx, job)
}

func openStore(t *testing.T, path string) *Store {
	t.Helper()
	store, err := Open(path, testInputs)
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

func testInputs(_ Service, evidence json.RawMessage) (planning.Inputs, error) {
	var inputs struct {
		Files  json.RawMessage `json:"files"`
		Source string          `json:"source"`
	}
	if err := json.Unmarshal(evidence, &inputs); err != nil {
		return planning.Inputs{}, err
	}
	return planning.NewInputs(inputs)
}

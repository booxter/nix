package jobs

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestNewGuidanceInvalidatesAnInflightPlan(t *testing.T) {
	ctx := context.Background()
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	job, err := store.Observe(ctx, Job{Service: Radarr, QueueID: 1, SourceFingerprint: "source"})
	if err != nil {
		t.Fatal(err)
	}

	if err := store.RequestAction(ctx, job.ID, Reconsider, "use both parts", 0, time.Now()); err != nil {
		t.Fatal(err)
	}
	job.Plan = json.RawMessage(`{"action":"join"}`)
	job.State = Ready
	if err := store.FinishPlanning(ctx, job); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale plan replaced new guidance: %v", err)
	}

	current, err := store.Get(ctx, job.ID)
	if err != nil || current.Guidance != "use both parts" || current.State != Observed {
		t.Fatalf("guidance lost: %+v, %v", current, err)
	}
}

func TestQueueRemovalExcludesRepairAndDisappearsFromCurrentJobs(t *testing.T) {
	ctx := context.Background()
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	job, err := store.Observe(ctx, Job{Service: Lidarr, QueueID: 1, DownloadID: "album"})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetPlan(ctx, job.ID, "", json.RawMessage(`{}`), "", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := store.RequestAction(ctx, job.ID, Delete, "", 0, time.Now()); err != nil {
		t.Fatal(err)
	}

	if _, err := store.Start(ctx, job.ID, time.Now()); !errors.Is(err, ErrConflict) {
		t.Fatalf("repair started after deletion was requested: %v", err)
	}
	requested, err := store.StartRemoval(ctx, job.ID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.RequestAction(ctx, job.ID, Reconsider, "retry", 0, time.Now()); !errors.Is(err, ErrConflict) {
		t.Fatalf("changed an active removal: %v", err)
	}

	if err := store.FinishRemoval(ctx, requested, nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	removed, err := store.Get(ctx, job.ID)
	if err != nil || removed.State != Removed || removed.InQueue || removed.PendingAction != "" {
		t.Fatalf("removal left a current job: %+v, %v", removed, err)
	}
}

func TestMissingQueueItemKeepsImportRecoveryEvidence(t *testing.T) {
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
	attempt.State = Importing
	attempt.ImportRequest = json.RawMessage(`{"track":1}`)
	if err := store.UpdateAttempt(ctx, attempt); err != nil {
		t.Fatal(err)
	}

	if err := store.ReconcileQueue(ctx, Lidarr, nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	current, err := store.Get(ctx, job.ID)
	if err != nil || current.InQueue || current.State != Importing {
		t.Fatalf("queue disappearance reset import: %+v, %v", current, err)
	}
	attempt, err = store.LatestAttempt(ctx, job.ID)
	if err != nil || string(attempt.ImportRequest) != `{"track":1}` {
		t.Fatalf("lost recovery request: %+v, %v", attempt, err)
	}
}

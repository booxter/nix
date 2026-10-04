package jobs

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func TestQueueIDChangePreservesJobAndPendingDelete(t *testing.T) {
	ctx := context.Background()
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	job, err := store.Observe(ctx, Job{Service: Lidarr, QueueID: 10, DownloadID: "download", Guidance: "keep guidance"})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.RequestAction(ctx, job.ID, Delete, "", 0, time.Now()); err != nil {
		t.Fatal(err)
	}
	present := []QueueKey{{QueueID: 20, DownloadID: "download"}}
	if err := store.ReconcileQueue(ctx, Lidarr, present, time.Now()); err != nil {
		t.Fatal(err)
	}
	observed, err := store.Observe(ctx, Job{Service: Lidarr, QueueID: 20, DownloadID: "download"})
	if err != nil || observed.ID != job.ID || observed.PendingAction != Delete || observed.Guidance != "keep guidance" {
		t.Fatalf("job changed during reassociation: %+v, %v", observed, err)
	}

	requested, err := store.StartRemoval(ctx, job.ID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.FinishRemoval(ctx, requested, nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := store.ReconcileQueue(ctx, Lidarr, present, time.Now()); err != nil {
		t.Fatal(err)
	}
	reappeared, err := store.Get(ctx, job.ID)
	if err != nil || !reappeared.InQueue || reappeared.State != Blocked {
		t.Fatalf("present download stayed removed: %+v, %v", reappeared, err)
	}
	if err := store.RequestAction(ctx, job.ID, Delete, "", 0, time.Now()); err != nil {
		t.Fatalf("cannot retry deletion: %v", err)
	}
}

func TestQueueReconciliationDoesNotMergeAlbumJobs(t *testing.T) {
	ctx := context.Background()
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	for _, id := range []int64{10, 20} {
		if _, err := store.Observe(ctx, Job{Service: Lidarr, QueueID: id, DownloadID: "download"}); err != nil {
			t.Fatal(err)
		}
	}
	present := []QueueKey{{QueueID: 30, DownloadID: "download"}}
	if err := store.ReconcileQueue(ctx, Lidarr, present, time.Now()); err == nil {
		t.Fatal("ambiguous albums were reassociated")
	}
	listed, err := store.List(ctx, Lidarr)
	if err != nil || len(listed) != 2 || listed[0].QueueID != 10 || listed[1].QueueID != 20 {
		t.Fatalf("ambiguous reconciliation changed jobs: %+v, %v", listed, err)
	}
	present = []QueueKey{{QueueID: 10, DownloadID: "download"}, {QueueID: 20, DownloadID: "download"}}
	if err := store.ReconcileQueue(ctx, Lidarr, present, time.Now()); err != nil {
		t.Fatalf("distinct known album rows rejected: %v", err)
	}
}

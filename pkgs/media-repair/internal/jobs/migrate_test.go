package jobs

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
)

func TestConversionPreservesReceiptsAndRejectsNonemptyDestination(t *testing.T) {
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	ctx := context.Background()
	batch := []MigratedJob{{
		Job:      Job{Service: Lidarr, QueueID: 1, DownloadID: "download", State: Imported},
		Attempts: []Attempt{{State: Imported, ImportReceipt: json.RawMessage(`{"history_id":42}`)}},
	}}
	if err := store.Import(ctx, batch); err != nil {
		t.Fatal(err)
	}
	if err := store.Import(ctx, batch); err == nil {
		t.Fatal("conversion overwrote a nonempty database")
	}
	listed, err := store.List(ctx, Lidarr)
	if err != nil || len(listed) != 1 || listed[0].State != Imported {
		t.Fatalf("converted jobs: %+v %v", listed, err)
	}
	attempts, err := store.Attempts(ctx, listed[0].ID)
	if err != nil || len(attempts) != 1 || string(attempts[0].ImportReceipt) != `{"history_id":42}` {
		t.Fatalf("converted attempts: %+v %v", attempts, err)
	}
}

func TestConversionRollsBackPartialBatch(t *testing.T) {
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	ctx := context.Background()
	entry := MigratedJob{Job: Job{Service: Radarr, QueueID: 1, DownloadID: "same"}}
	if err := store.Import(ctx, []MigratedJob{entry, entry}); err == nil {
		t.Fatal("accepted duplicate queue identities")
	}
	listed, err := store.List(ctx, Radarr)
	if err != nil || len(listed) != 0 {
		t.Fatalf("partial conversion remained: %+v %v", listed, err)
	}
}

package jobs

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/planning"
)

func TestPlanningInputsAreRequired(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jobs.db")
	if _, err := Open(path, nil); err == nil {
		t.Fatal("opened a store without planning input projection")
	}
	store, err := Open(path, func(Service, json.RawMessage) (planning.Inputs, error) {
		return planning.Inputs{}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	if _, err := store.Observe(ctx, Job{Service: Radarr, QueueID: 1, Evidence: json.RawMessage(`{}`)}); err == nil {
		t.Fatal("accepted plannable evidence without inputs")
	}
	listed, err := store.List(ctx, Radarr)
	if err != nil || len(listed) != 0 {
		t.Fatalf("invalid observation created jobs: %+v, %v", listed, err)
	}
}

package radarrreview

import (
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/review"
	shadowrunner "github.com/booxter/nix-config/media-repair/internal/shadow"
)

func TestSnapshotDistinguishesActiveAndUnprocessedWarnings(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 25, 2, 0, 0, 0, time.UTC)
	snapshot, err := Snapshot(shadowrunner.Report{Queue: []controller.RadarrQueueRecord{
		{ID: 1, Title: "Downloading", Status: "downloading", TrackedDownloadStatus: "ok"},
		{ID: 2, Title: "Needs review", Status: "completed", TrackedDownloadStatus: "warning"},
	}}, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Current) != 2 || snapshot.Current[0].State != review.StateActive ||
		snapshot.Current[1].State != review.StateNotProcessed {
		t.Fatalf("snapshot = %#v", snapshot)
	}
}

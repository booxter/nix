package review

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestStoreRetainsDisappearedItemsAsHistory(t *testing.T) {
	t.Parallel()
	directory := filepath.Join(t.TempDir(), "lidarr")
	if err := os.Mkdir(directory, 0o750); err != nil {
		t.Fatal(err)
	}
	store, err := NewStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	firstAt := time.Date(2026, 9, 25, 1, 0, 0, 0, time.UTC)
	item := Item{
		QueueID: 7, Title: "Album", QueueStatus: "completed", TrackedStatus: "warning",
		State: StateReviewed, LastSeenAt: firstAt, CaseID: "case",
		Decision: &Decision{Action: "no_repair", Explanation: "Incomplete release."},
	}
	if err := store.Publish(Snapshot{
		Version: SnapshotVersion, Service: ServiceLidarr, GeneratedAt: firstAt,
		Current: []Item{item},
	}); err != nil {
		t.Fatal(err)
	}
	secondAt := firstAt.Add(time.Hour)
	if err := store.Publish(Snapshot{
		Version: SnapshotVersion, Service: ServiceLidarr, GeneratedAt: secondAt,
		Current: []Item{},
	}); err != nil {
		t.Fatal(err)
	}
	got, found, err := store.Read()
	if err != nil || !found {
		t.Fatalf("read snapshot: found=%t err=%v", found, err)
	}
	if len(got.Current) != 0 || len(got.History) != 1 {
		t.Fatalf("snapshot = %#v", got)
	}
	historical := got.History[0]
	if historical.State != StateNoLongerQueued || historical.NoLongerQueuedAt == nil ||
		!historical.NoLongerQueuedAt.Equal(secondAt) || historical.Decision == nil {
		t.Fatalf("historical item = %#v", historical)
	}
	info, err := os.Stat(filepath.Join(directory, snapshotFileName))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("snapshot mode = %o", info.Mode().Perm())
	}
}

func TestStoreRejectsServiceReuse(t *testing.T) {
	t.Parallel()
	directory := filepath.Join(t.TempDir(), "review")
	if err := os.Mkdir(directory, 0o750); err != nil {
		t.Fatal(err)
	}
	store, err := NewStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 25, 1, 0, 0, 0, time.UTC)
	if err := store.Publish(Snapshot{
		Version: SnapshotVersion, Service: ServiceLidarr, GeneratedAt: now,
		Current: []Item{},
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.Publish(Snapshot{
		Version: SnapshotVersion, Service: ServiceRadarr, GeneratedAt: now,
		Current: []Item{},
	}); err == nil {
		t.Fatal("review directory was reused for another service")
	}
}

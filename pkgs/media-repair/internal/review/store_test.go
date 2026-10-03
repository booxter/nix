package review

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/queueaction"
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

func TestApplyQueueRemovalsMovesCompletedItemToHistory(t *testing.T) {
	t.Parallel()
	observedAt := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	attemptedAt := observedAt.Add(time.Minute)
	item, action := removalFixture(t, observedAt, attemptedAt)
	snapshot := Snapshot{
		Version: SnapshotVersion, Service: ServiceLidarr, GeneratedAt: attemptedAt,
		Current: []Item{item},
	}

	if err := ApplyQueueRemovals(&snapshot, []queueaction.Processed{action}); err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Current) != 0 || len(snapshot.History) != 1 {
		t.Fatalf("snapshot = %#v", snapshot)
	}
	historical := snapshot.History[0]
	if historical.State != StateNoLongerQueued || historical.NoLongerQueuedAt == nil ||
		!historical.NoLongerQueuedAt.Equal(attemptedAt) || historical.QueueRemoval == nil ||
		historical.QueueRemoval.State != queueaction.StateCompleted {
		t.Fatalf("historical item = %#v", historical)
	}
}

func TestApplyQueueRemovalsKeepsFailedItemCurrent(t *testing.T) {
	t.Parallel()
	observedAt := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	attemptedAt := observedAt.Add(time.Minute)
	item, action := removalFixture(t, observedAt, attemptedAt)
	action.Result.State = queueaction.StateFailed
	action.Result.Outcome = ""
	action.Result.Failure = "remove_failed"
	snapshot := Snapshot{
		Version: SnapshotVersion, Service: ServiceLidarr, GeneratedAt: attemptedAt,
		Current: []Item{item},
	}

	if err := ApplyQueueRemovals(&snapshot, []queueaction.Processed{action}); err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Current) != 1 || len(snapshot.History) != 0 ||
		snapshot.Current[0].QueueRemoval == nil ||
		snapshot.Current[0].QueueRemoval.State != queueaction.StateFailed {
		t.Fatalf("snapshot = %#v", snapshot)
	}
}

func TestStoreMergesImmediateQueueRemovalWithoutDuplicateHistory(t *testing.T) {
	t.Parallel()
	directory := filepath.Join(t.TempDir(), "lidarr")
	if err := os.Mkdir(directory, 0o750); err != nil {
		t.Fatal(err)
	}
	store, err := NewStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	observedAt := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	attemptedAt := observedAt.Add(time.Minute)
	item, action := removalFixture(t, observedAt, attemptedAt)
	if err := store.Publish(Snapshot{
		Version: SnapshotVersion, Service: ServiceLidarr, GeneratedAt: observedAt,
		Current: []Item{item},
	}); err != nil {
		t.Fatal(err)
	}
	snapshot := Snapshot{
		Version: SnapshotVersion, Service: ServiceLidarr, GeneratedAt: attemptedAt,
		Current: []Item{item},
	}
	if err := ApplyQueueRemovals(&snapshot, []queueaction.Processed{action}); err != nil {
		t.Fatal(err)
	}
	if err := store.Publish(snapshot); err != nil {
		t.Fatal(err)
	}
	got, found, err := store.Read()
	if err != nil || !found {
		t.Fatalf("read snapshot: found=%t err=%v", found, err)
	}
	if len(got.Current) != 0 || len(got.History) != 1 ||
		got.History[0].QueueRemoval == nil ||
		got.History[0].QueueRemoval.State != queueaction.StateCompleted {
		t.Fatalf("snapshot = %#v", got)
	}
}

func removalFixture(
	t *testing.T,
	observedAt time.Time,
	attemptedAt time.Time,
) (Item, queueaction.Processed) {
	t.Helper()
	identity := queueaction.QueueIdentity{
		QueueID: 7, DownloadID: "download", SubjectID: 42,
		Status: "completed", TrackedDownloadStatus: "warning",
	}
	request, err := queueaction.NewRequest(
		queueaction.ServiceLidarr,
		"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		identity,
		observedAt,
	)
	if err != nil {
		t.Fatal(err)
	}
	item := Item{
		QueueID: 7, Title: "Artist - Album", QueueStatus: "completed",
		TrackedStatus: "warning", State: StateReviewed, CaseID: request.CaseID,
		LastSeenAt: observedAt, QueueIdentity: &identity,
		Decision: &Decision{Action: "no_repair", Explanation: "Incomplete release."},
	}
	action := queueaction.Processed{
		Request: request,
		Result: queueaction.Result{
			RequestID: request.RequestID, State: queueaction.StateCompleted, Attempts: 1,
			AttemptedAt: attemptedAt, Outcome: "finalized",
		},
	}
	return item, action
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

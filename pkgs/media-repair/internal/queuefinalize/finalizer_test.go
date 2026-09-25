package queuefinalize

import (
	"context"
	"errors"
	"testing"
	"time"
)

type testClock struct{ now time.Time }

func (clock *testClock) Now() time.Time {
	clock.now = clock.now.Add(time.Second)
	return clock.now
}

func TestFinalizerRefreshesAndFinalizesOneExactCandidate(t *testing.T) {
	t.Parallel()
	first := eligibleEntry(2)
	second := eligibleEntry(1)
	reads := 0
	var removed []int64
	finalizer, err := New(Dependencies{
		Service: "Lidarr", StateDirectory: t.TempDir(),
		ReadQueue: func(context.Context) ([]Entry, error) {
			reads++
			return []Entry{first, second}, nil
		},
		Remove: func(_ context.Context, queueID int64) error {
			removed = append(removed, queueID)
			return nil
		},
		Clock: &testClock{now: time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)},
	})
	if err != nil {
		t.Fatal(err)
	}
	report, err := finalizer.Run(context.Background(), []Entry{first, second}, 1)
	if err != nil || reads != 1 || report.Finalized != 1 || report.Reconciled != 0 ||
		len(removed) != 1 || removed[0] != second.QueueID {
		t.Fatalf("report = %#v, reads = %d, removed = %v, error = %v", report, reads, removed, err)
	}
}

func TestFinalizerRefusesChangedQueueEntry(t *testing.T) {
	t.Parallel()
	candidate := eligibleEntry(1)
	changed := candidate
	changed.DownloadID = "different"
	removed := 0
	finalizer, err := New(Dependencies{
		Service: "Radarr", StateDirectory: t.TempDir(),
		ReadQueue: func(context.Context) ([]Entry, error) { return []Entry{changed}, nil },
		Remove:    func(context.Context, int64) error { removed++; return nil },
		Clock:     &testClock{now: time.Now()},
	})
	if err != nil {
		t.Fatal(err)
	}
	report, err := finalizer.Run(context.Background(), []Entry{candidate}, 1)
	if err != nil || report.Finalized != 0 || removed != 0 {
		t.Fatalf("report = %#v, removed = %d, error = %v", report, removed, err)
	}
}

func TestFinalizerReconcilesAmbiguousSuccessfulRemoval(t *testing.T) {
	t.Parallel()
	candidate := eligibleEntry(1)
	wantErr := errors.New("connection closed")
	queue := []Entry{candidate}
	finalizer, err := New(Dependencies{
		Service: "Lidarr", StateDirectory: t.TempDir(),
		ReadQueue: func(context.Context) ([]Entry, error) { return queue, nil },
		Remove: func(context.Context, int64) error {
			queue = nil
			return wantErr
		},
		Clock: &testClock{now: time.Now()},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := finalizer.Run(context.Background(), []Entry{candidate}, 1); !errors.Is(err, wantErr) {
		t.Fatalf("first run error = %v", err)
	}
	report, err := finalizer.Run(context.Background(), nil, 1)
	if err != nil || report.Finalized != 0 || report.Reconciled != 1 {
		t.Fatalf("recovery report = %#v, error = %v", report, err)
	}
}

func eligibleEntry(queueID int64) Entry {
	return Entry{
		QueueID: queueID, DownloadID: "download", SubjectID: 42,
		Status: "completed", TrackedDownloadStatus: "warning",
	}
}

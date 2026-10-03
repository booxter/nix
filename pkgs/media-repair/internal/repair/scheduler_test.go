package repair

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

func TestRemovalDoesNotWaitForPlanner(t *testing.T) {
	store, err := jobs.Open(filepath.Join(t.TempDir(), "jobs.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	observed := jobs.Job{Service: jobs.Lidarr, QueueID: 1, DownloadID: "planning", Evidence: json.RawMessage(`{}`)}
	first, err := store.Observe(context.Background(), observed)
	if err != nil {
		t.Fatal(err)
	}
	observed.QueueID, observed.DownloadID = 2, "remove"
	second, err := store.Observe(context.Background(), observed)
	if err != nil {
		t.Fatal(err)
	}

	service := &waitingService{
		fakeAdapter: fakeAdapter{store: store},
		observed: Observation{
			Jobs:  []jobs.Job{first, second},
			Queue: []jobs.QueueKey{{QueueID: 1, DownloadID: "planning"}, {QueueID: 2, DownloadID: "remove"}},
		},
		planning: make(chan struct{}),
		removed:  make(chan int64, 1),
	}
	wake := make(chan struct{}, 1)
	scheduler := Scheduler{
		Store: store, Service: service, Name: jobs.Lidarr,
		Now: time.Now, Interval: time.Hour, Wake: wake,
		Disabled: func() (bool, error) { return false, nil },
		Log:      slog.New(slog.NewTextHandler(io.Discard, nil)),
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		scheduler.Run(ctx)
	}()

	select {
	case <-service.planning:
	case <-time.After(5 * time.Second):
		t.Fatal("planner did not start")
	}
	if err := store.RequestAction(ctx, second.ID, jobs.Delete, "", 0, time.Now()); err != nil {
		t.Fatal(err)
	}
	wake <- struct{}{}

	select {
	case id := <-service.removed:
		if id != second.ID {
			t.Fatalf("removed job %d, wanted %d", id, second.ID)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("removal waited for the blocked planner")
	}

	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("scheduler did not stop")
	}

	removed, err := store.Get(context.Background(), second.ID)
	if err != nil || removed.State != jobs.Removed || removed.InQueue {
		t.Fatalf("removal not reflected in UI state: %+v, %v", removed, err)
	}
}

type waitingService struct {
	fakeAdapter
	observed Observation
	planning chan struct{}
	removed  chan int64
}

func (service *waitingService) Observe(context.Context, []jobs.Job) (Observation, error) {
	return service.observed, nil
}

func (service *waitingService) Plan(ctx context.Context, _ jobs.Job) (Decision, error) {
	close(service.planning)
	<-ctx.Done()
	return Decision{}, ctx.Err()
}

func (service *waitingService) Ready(jobs.Job) bool {
	return true
}

func (service *waitingService) Remove(_ context.Context, job jobs.Job) error {
	service.removed <- job.ID
	return nil
}

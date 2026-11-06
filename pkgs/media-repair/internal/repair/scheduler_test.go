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

func TestRepeatedInputsDoNotBuyAnotherPlan(t *testing.T) {
	ctx := context.Background()
	store, err := jobs.Open(filepath.Join(t.TempDir(), "jobs.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	service := &countingPlanner{}
	service.observed = Observation{
		Jobs:  []jobs.Job{{QueueID: 1, SourceFingerprint: "case-a", PlanningFingerprint: "files-a", Evidence: json.RawMessage(`{}`)}},
		Queue: []jobs.QueueKey{{QueueID: 1}},
	}
	scheduler := Scheduler{
		Store: store, Service: service, Name: jobs.Lidarr, Now: time.Now,
		Disabled: func() (bool, error) { return true, nil },
		Log:      slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	for _, step := range []struct {
		name, caseID, inputs string
		calls                int
	}{
		{"first observation", "case-a", "files-a", 1},
		{"assessment changed", "case-a-new-score", "files-a", 1},
		{"files changed", "case-b", "files-b", 2},
		{"old inputs returned", "case-a-again", "files-a", 2},
	} {
		t.Run(step.name, func(t *testing.T) {
			service.observed.Jobs[0].SourceFingerprint = step.caseID
			service.observed.Jobs[0].PlanningFingerprint = step.inputs
			if err := scheduler.observe(ctx); err != nil {
				t.Fatal(err)
			}
			if err := scheduler.advance(ctx); err != nil {
				t.Fatal(err)
			}
			if service.calls != step.calls {
				t.Fatalf("paid requests = %d, want %d", service.calls, step.calls)
			}
		})
	}
	listed, err := store.List(ctx, jobs.Lidarr)
	if err != nil || len(listed) != 1 {
		t.Fatalf("jobs: %+v, %v", listed, err)
	}
	if err := store.RequestAction(ctx, listed[0].ID, jobs.Reconsider, "try again", 0, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := scheduler.advance(ctx); err != nil {
		t.Fatal(err)
	}
	if service.calls != 3 {
		t.Fatalf("operator request did not cause one new plan: %d", service.calls)
	}
}

type countingPlanner struct {
	waitingService
	calls int
}

func (service *countingPlanner) Plan(context.Context, jobs.Job) (Decision, error) {
	service.calls++
	return Decision{Data: json.RawMessage(`{"action":"no_repair"}`), Reason: "no repair"}, nil
}

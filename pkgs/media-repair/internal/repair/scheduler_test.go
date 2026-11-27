package repair

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

func TestTemporaryPreparationReadIsRetriedWithExistingPlan(t *testing.T) {
	engine, adapter, job := fixture(t)
	ctx := context.Background()
	now := engine.Now().UTC()
	service := &waitingService{fakeAdapter: *adapter}
	scheduler := Scheduler{
		Store: engine.Store, Service: service, Name: jobs.Radarr,
		Now: func() time.Time { return now }, Disabled: func() (bool, error) { return false, nil },
	}
	service.authorizeError = RetryableRead(fmt.Errorf("read download: %w", context.DeadlineExceeded))
	if err := scheduler.advance(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected Transmission timeout, got %v", err)
	}
	waiting, err := engine.Store.Get(ctx, job.ID)
	if err != nil || waiting.State != jobs.Ready || !waiting.RetryAt.After(now) {
		t.Fatalf("repair was not scheduled to retry: %+v, %v", waiting, err)
	}
	if service.submissions != 0 {
		t.Fatal("submitted an import after a failed source check")
	}

	service.authorizeError = nil
	service.imported = []servarr.ImportedFile{{MovieFileID: 42}}
	if err := scheduler.advance(ctx); err != nil || service.submissions != 0 {
		t.Fatalf("retried during backoff: %v, submissions: %d", err, service.submissions)
	}

	now = waiting.RetryAt
	if err := scheduler.advance(ctx); err != nil {
		t.Fatal(err)
	}
	assertState(t, engine, job.ID, jobs.Imported)
	attempts, err := engine.Store.Attempts(ctx, job.ID)
	if err != nil || len(attempts) != 2 || service.submissions != 1 ||
		attempts[0].State != jobs.Failed || string(attempts[1].Plan) != string(attempts[0].Plan) {
		t.Fatalf("retry did not import once with its existing plan: %+v, %v", attempts, err)
	}
}

func TestPendingImportFoundDuringAuthorizationRetriesAtGraceDeadline(t *testing.T) {
	engine, adapter, job := fixture(t)
	ctx := t.Context()
	start := time.Now().UTC()
	now := start.Add(time.Minute)
	grace := ImportGracePeriod{Duration: 15 * time.Minute, Now: func() time.Time { return now }}
	service := &waitingService{fakeAdapter: *adapter}
	scheduler := Scheduler{
		Store: engine.Store, Service: service, Name: jobs.Radarr,
		Now: grace.Now, Disabled: func() (bool, error) { return false, nil },
	}

	// The saved plan was ready, but the fresh queue read found a pending import.
	service.authorizeError = grace.CheckImportState("importPending", start)
	if err := scheduler.advance(ctx); err == nil {
		t.Fatal("expected preparation to wait for the media service")
	}
	waiting, err := engine.Store.Get(ctx, job.ID)
	deadline := start.Add(grace.Duration)
	if err != nil || waiting.State != jobs.Ready || !waiting.RetryAt.Equal(deadline) || service.submissions != 0 {
		t.Fatalf("expected a pending retry at %v, got %+v, %v", deadline, waiting, err)
	}

	now = deadline
	service.authorizeError = grace.CheckImportState("importPending", start)
	if err := scheduler.advance(ctx); err != nil || service.submissions != 1 {
		t.Fatalf("retry at deadline: %v, submissions: %d", err, service.submissions)
	}
}

func TestRemovalDoesNotWaitForPlanner(t *testing.T) {
	store, err := jobs.Open(filepath.Join(t.TempDir(), "jobs.db"), testInputs)
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
			Jobs: []jobs.Job{first, second},
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
	if err := store.RequestRemoval(ctx, second, time.Now()); err != nil {
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

func (service *waitingService) PlanningInputs(evidence json.RawMessage) (planning.Inputs, error) {
	return testInputs("", evidence)
}

func testInputs(_ jobs.Service, evidence json.RawMessage) (planning.Inputs, error) {
	var inputs struct {
		Files string `json:"files"`
	}
	if err := json.Unmarshal(evidence, &inputs); err != nil {
		return planning.Inputs{}, err
	}
	return planning.NewInputs(inputs)
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
	store, err := jobs.Open(filepath.Join(t.TempDir(), "jobs.db"), testInputs)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	service := &countingPlanner{}
	service.observed = Observation{
		Jobs: []jobs.Job{{QueueID: 1, SourceFingerprint: "case-a", Evidence: json.RawMessage(`{"files":"a"}`)}},
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
		{"first observation", "case-a", "a", 1},
		{"assessment changed", "case-a-new-score", "a", 1},
		{"files changed", "case-b", "b", 2},
		{"old inputs returned", "case-a-again", "a", 2},
	} {
		t.Run(step.name, func(t *testing.T) {
			service.observed.Jobs[0].SourceFingerprint = step.caseID
			evidence, err := json.Marshal(struct {
				Files string `json:"files"`
			}{Files: step.inputs})
			if err != nil {
				t.Fatal(err)
			}
			service.observed.Jobs[0].Evidence = evidence
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
	if err := store.RequestReconsideration(ctx, listed[0], planning.Answer{Guidance: "try again"}, time.Now()); err != nil {
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
	return PlannerStop(json.RawMessage(`{"action":"no_repair"}`), "no_repair_needed", "no repair", nil), nil
}

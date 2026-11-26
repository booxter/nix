package repair_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/repair"
	"github.com/booxter/nix-config/media-repair/internal/repairlidarr"
	"github.com/booxter/nix-config/media-repair/internal/repairradarr"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

// Exercise the scheduler and persistent store using each production adapter's
// input projection. Collection and paid inference are explicit test boundaries.
func TestAdaptersSharePlanningHistory(t *testing.T) {
	for _, adapter := range []struct {
		name    jobs.Service
		service repair.Service
		observe func(*testing.T, string) jobs.Job
	}{
		{jobs.Radarr, &repairradarr.Adapter{}, radarrObservation},
		{jobs.Lidarr, &repairlidarr.Adapter{}, lidarrObservation},
	} {
		t.Run(string(adapter.name), func(t *testing.T) {
			if _, err := adapter.service.PlanningInputs(json.RawMessage(`{}`)); err == nil {
				t.Fatal("adapter accepted missing planning evidence")
			}
			fixture := newHistoryFixture(t, adapter.name, adapter.service)
			observe := func(variant string, calls int64) jobs.Job {
				t.Helper()
				return fixture.observe(adapter.observe(t, variant), calls)
			}
			observe("original", 1)
			observe("noise", 1)
			observe("order", 1)
			observe("source", 2)
			observe("original", 2)
			fixture.close()
			fixture.start()
			job := observe("noise", 2)
			if err := fixture.store.RequestAction(context.Background(), job.ID, jobs.Reconsider, "try again", 0, job.UpdatedAt); err != nil {
				t.Fatal(err)
			}
			observe("original", 3)
			observe("target", 4)
			observe("diagnostics", 5)
		})
	}
}

type historyFixture struct {
	t       *testing.T
	name    jobs.Service
	path    string
	service *observedService
	store   *jobs.Store
	clock   atomic.Int64
	cancel  context.CancelFunc
	done    chan struct{}
}

func newHistoryFixture(t *testing.T, name jobs.Service, adapter repair.Service) *historyFixture {
	t.Helper()
	fixture := &historyFixture{
		t: t, name: name, path: filepath.Join(t.TempDir(), "jobs.db"),
		service: &observedService{
			Service: adapter, observations: make(chan jobs.Job), wake: make(chan struct{}, 1),
		},
	}
	fixture.clock.Store(time.Date(2026, 11, 26, 0, 0, 0, 0, time.UTC).UnixNano())
	fixture.start()
	t.Cleanup(fixture.close)
	return fixture
}

func (fixture *historyFixture) start() {
	fixture.t.Helper()
	var err error
	fixture.store, err = jobs.Open(fixture.path, fixture.planningInputs)
	if err != nil {
		fixture.t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	fixture.cancel = cancel
	fixture.done = make(chan struct{})
	scheduler := &repair.Scheduler{
		Store: fixture.store, Service: fixture.service, Name: fixture.name,
		Now:      func() time.Time { return time.Unix(0, fixture.clock.Load()).UTC() },
		Interval: time.Minute, Wake: fixture.service.wake,
		Disabled: func() (bool, error) { return true, nil },
		Log:      slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	go func() {
		defer close(fixture.done)
		scheduler.Run(ctx)
	}()
}

func (fixture *historyFixture) planningInputs(_ jobs.Service, evidence json.RawMessage) (planning.Inputs, error) {
	return fixture.service.PlanningInputs(evidence)
}

func (fixture *historyFixture) close() {
	fixture.t.Helper()
	fixture.cancel()
	select {
	case <-fixture.done:
	case <-time.After(5 * time.Second):
		fixture.t.Fatal("scheduler did not stop")
	}
	if err := fixture.store.Close(); err != nil {
		fixture.t.Fatal(err)
	}
}

func (fixture *historyFixture) observe(job jobs.Job, calls int64) jobs.Job {
	fixture.t.Helper()
	now := time.Unix(0, fixture.clock.Add(int64(time.Hour))).UTC()
	fixture.service.wake <- struct{}{}
	select {
	case fixture.service.observations <- job:
	case <-time.After(5 * time.Second):
		fixture.t.Fatal("scheduler did not collect an observation")
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		listed, err := fixture.store.List(context.Background(), fixture.name)
		if err != nil {
			fixture.t.Fatal(err)
		}
		if len(listed) == 1 && listed[0].UpdatedAt.Equal(now) && listed[0].State == jobs.Blocked {
			if actual := fixture.service.calls.Load(); actual != calls {
				fixture.t.Fatalf("paid requests = %d, want %d", actual, calls)
			}
			return listed[0]
		}
		time.Sleep(time.Millisecond)
	}
	fixture.t.Fatal("observation did not settle")
	return jobs.Job{}
}

type observedService struct {
	repair.Service
	observations chan jobs.Job
	wake         chan struct{}
	calls        atomic.Int64
}

func (service *observedService) Observe(ctx context.Context, _ []jobs.Job) (repair.Observation, error) {
	select {
	case job := <-service.observations:
		return repair.Observation{Jobs: []jobs.Job{job}}, nil
	case <-ctx.Done():
		return repair.Observation{}, ctx.Err()
	}
}

func (service *observedService) Plan(context.Context, jobs.Job) (repair.Decision, error) {
	service.calls.Add(1)
	return repair.Decision{Data: json.RawMessage(`{"action":"no_repair"}`), Reason: "no repair", Result: planning.Result{Outcome: planning.Decline}}, nil
}

func radarrObservation(t *testing.T, variant string) jobs.Job {
	t.Helper()
	data, err := os.ReadFile("../../contracts/v3/examples/repair-case-joinable.json")
	if err != nil {
		t.Fatal(err)
	}
	repairCase, err := contracts.DecodeCase(data)
	if err != nil {
		t.Fatal(err)
	}
	repairCase.Radarr.Failure.TrackedDownloadState = "importBlocked"
	switch variant {
	case "noise":
		repairCase.ObservedAt = repairCase.ObservedAt.Add(time.Hour)
		repairCase.Radarr.Failure.TrackedDownloadState = "importPending"
	case "order":
		slices.Reverse(repairCase.Files)
		slices.Reverse(repairCase.Capabilities)
	case "source":
		repairCase.Files[0].Fingerprint = "sha256:" + strings.Repeat("d", 64)
	case "target":
		repairCase.Radarr.Movie.Title = "Another movie"
	case "diagnostics":
		repairCase.Radarr.Failure.ErrorMessage = "A different rejection"
	}
	repairCase.CaseID, err = contracts.CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	evidence, err := json.Marshal(repairradarr.Evidence{Case: repairCase})
	if err != nil {
		t.Fatal(err)
	}
	return jobs.Job{QueueID: 1, SourceFingerprint: repairCase.CaseID, Evidence: evidence}
}

func lidarrObservation(t *testing.T, variant string) jobs.Job {
	t.Helper()
	repairCase := lidarrcontracts.Case{
		SchemaVersion: lidarrcontracts.SchemaVersion, ObservedAt: time.Unix(1, 0).UTC(),
		Queue: lidarrcontracts.Queue{QueueID: 1, Title: "Album", DownloadRef: "download:one", Messages: []string{}},
		Album: lidarrcontracts.Album{AlbumID: 1, ArtistID: 2, Artist: "Artist", Title: "Album"},
		Releases: []lidarrcontracts.Release{{
			ReleaseID: 3, ForeignReleaseID: "release", Title: "Album", Format: "CD",
			Countries: []string{}, Labels: []string{}, TrackCount: 1, MediumCount: 1,
		}},
		Tracks: []lidarrcontracts.Track{{TrackID: 4, ReleaseID: 3, Number: "1", AbsoluteNumber: 1, MediumNumber: 1, Title: "Track", DurationMS: 1000}},
		Artifacts: []lidarrcontracts.Artifact{{
			ArtifactID: "artifact:one", RelativePath: "01.flac", Fingerprint: "sha256:" + strings.Repeat("a", 64),
			SizeBytes: 100, Formats: []string{"flac"}, Tags: []lidarrcontracts.Tag{}, Streams: []lidarrcontracts.Stream{},
		}},
		Assessments: []lidarrcontracts.Assessment{}, Capabilities: []lidarrcontracts.Capability{},
	}
	switch variant {
	case "noise":
		repairCase.Queue.Messages = []string{"fluctuating assessment"}
	case "source":
		repairCase.Artifacts[0].Fingerprint = "sha256:" + strings.Repeat("b", 64)
	case "target":
		repairCase.Album.Title = "Another album"
	case "diagnostics":
		repairCase.Releases[0].Title = "Another release"
	}
	var err error
	repairCase.CaseID, err = lidarrcontracts.CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	data, err := lidarrcontracts.EncodeCase(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	evidence, err := json.Marshal(lidarrrepair.Record{Case: data})
	if err != nil {
		t.Fatal(err)
	}
	return jobs.Job{QueueID: 1, SourceFingerprint: repairCase.CaseID, Evidence: evidence}
}

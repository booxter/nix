package repairui

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

type fixture struct {
	store   *jobs.Store
	handler http.Handler
	job     jobs.Job
	wakes   []jobs.Service
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	store, err := jobs.Open(filepath.Join(t.TempDir(), "jobs.db"), testInputs)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })

	job, err := store.Observe(context.Background(), jobs.Job{
		Service:    jobs.Lidarr,
		QueueID:    42,
		DownloadID: "album",
		Title:      "Album <script>alert(1)</script>",
		UpdatedAt:  time.Now().UTC(),
	})
	if err != nil {
		t.Fatal(err)
	}

	fixture := &fixture{store: store, job: job}
	fixture.handler, err = New(Config{
		Store:   store,
		Origins: []string{"https://repairr.home.arpa"},
		Wake: func(service jobs.Service) {
			fixture.wakes = append(fixture.wakes, service)
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return fixture
}

func (fixture *fixture) get(path string) *httptest.ResponseRecorder {
	response := httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
	return response
}

func TestRemovalWakesSchedulerAndLeavesCurrentListAfterCompletion(t *testing.T) {
	fixture := newFixture(t)
	response := httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, fixture.actionRequest(t, fixture.job.ID, "remove", actionRequest{}))
	if response.Code != http.StatusNoContent {
		t.Fatalf("request: %d %s", response.Code, response.Body.String())
	}
	if len(fixture.wakes) != 1 || fixture.wakes[0] != jobs.Lidarr {
		t.Fatalf("scheduler not notified: %v", fixture.wakes)
	}

	ctx := context.Background()
	job, err := fixture.store.Get(ctx, fixture.job.ID)
	if err != nil || job.PendingAction != jobs.Delete {
		t.Fatalf("request not durable: %+v %v", job, err)
	}
	job, err = fixture.store.StartRemoval(ctx, job.ID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := fixture.store.FinishRemoval(ctx, job, nil, time.Now()); err != nil {
		t.Fatal(err)
	}

	if current := fixture.listJobs(t, "view=inbox&service=lidarr"); len(current) != 0 {
		t.Fatalf("removed item remains current: %+v", current)
	}
	if history := fixture.listJobs(t, "view=history"); len(history) != 1 || history[0].ID != job.ID {
		t.Fatalf("removed item missing from history: %+v", history)
	}
}

func TestRemovalRejectsCrossSiteAndMissingToken(t *testing.T) {
	for _, scenario := range []string{"foreign origin", "missing cookie", "cross-site fetch"} {
		t.Run(scenario, func(t *testing.T) {
			fixture := newFixture(t)
			request := fixture.actionRequest(t, fixture.job.ID, "remove", actionRequest{})
			switch scenario {
			case "foreign origin":
				request.Header.Set("Origin", "https://attacker.invalid")
			case "missing cookie":
				request.Header.Del("Cookie")
			case "cross-site fetch":
				request.Header.Set("Sec-Fetch-Site", "cross-site")
			}

			response := httptest.NewRecorder()
			fixture.handler.ServeHTTP(response, request)
			if response.Code != http.StatusForbidden || len(fixture.wakes) != 0 {
				t.Fatalf("unsafe request accepted: %d, wakes=%v", response.Code, fixture.wakes)
			}
		})
	}
}

func TestNewReviewSavesGuidanceWhileInspectionIsBlocked(t *testing.T) {
	fixture := newFixture(t)
	ctx := context.Background()
	job, err := fixture.store.Observe(ctx, jobs.Job{
		Service: jobs.Radarr, QueueID: 101, CollectionError: "incomplete_download",
	})
	if err != nil {
		t.Fatal(err)
	}

	minutes := int64(15)
	input := actionRequest{Guidance: "Use the extended cut.", RuntimeMinutes: &minutes}
	review := fixture.actionRequest(t, job.ID, "reconsider", input)
	oldRemoval := fixture.actionRequest(t, job.ID, "remove", actionRequest{})
	response := httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, review)
	if response.Code != http.StatusNoContent {
		t.Fatalf("request review: %d %s", response.Code, response.Body)
	}
	response = httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, oldRemoval)
	if response.Code != http.StatusConflict {
		t.Fatalf("old removal confirmation: %d %s", response.Code, response.Body)
	}
	current, err := fixture.store.Get(ctx, job.ID)
	if err != nil || current.PendingAction != jobs.Reconsider || current.Guidance != input.Guidance ||
		current.RuntimeToleranceMS != 900_000 || len(fixture.wakes) != 1 {
		t.Fatalf("queued review: %+v, %v", current, err)
	}
}

func (fixture *fixture) listJobs(t *testing.T, query string) []jobSummary {
	t.Helper()
	response := fixture.get("/api/jobs?" + query)
	var listed []jobSummary
	if err := json.Unmarshal(response.Body.Bytes(), &listed); err != nil || response.Code != http.StatusOK {
		t.Fatalf("list jobs: %d %s", response.Code, response.Body)
	}
	return listed
}

func TestJobsAPIExplainsSavedRadarrStop(t *testing.T) {
	fixture := newFixture(t)
	ctx := context.Background()
	job, err := fixture.store.Observe(ctx, jobs.Job{
		Service: jobs.Radarr, QueueID: 100, Evidence: json.RawMessage(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	// Earlier versions stored the explanation only in the planner's decision.
	job.State, job.Outcome, job.Reason = jobs.Blocked, jobs.OutcomeOther, "unsafe_to_repair"
	job.Plan = json.RawMessage(`{"action":"no_repair","reason":"unsafe_to_repair","explanation":"The movie files overlap."}`)
	if err := fixture.store.FinishPlanning(ctx, job); err != nil {
		t.Fatal(err)
	}

	response := fixture.get("/api/jobs?service=radarr")
	var listed []jobSummary
	if err := json.Unmarshal(response.Body.Bytes(), &listed); err != nil {
		t.Fatal(err)
	}
	if len(listed) != 1 || listed[0].ReasonCode != "unsafe_to_repair" || listed[0].Reason != "The movie files overlap." {
		t.Fatalf("unexpected stop reason: %s", response.Body)
	}
}

func TestBlockedActivityExplainsReasonsAndSearchesMediaIdentity(t *testing.T) {
	fixture := newFixture(t)
	ctx := context.Background()
	for index, sample := range []struct {
		title, error, evidence, plan string
	}{
		{"release.flac", "", `{"case":{"album":{"artist":"Moby","title":"All Visible Objects"}}}`, `{"action":"no_repair","reason":"unsafe_to_repair","explanation":"These remixes do not match the original album tracks."}`},
		{"unfinished movie", "Radarr queue record 123 is ineligible: [incomplete_download unsupported_queue_state]", `{}`, `{}`},
		{"old provider failure", "", `{}`, `{"action":"no_repair","explanation":"The planner could not produce a valid decision within its attempt limit."}`},
	} {
		job, err := fixture.store.Observe(ctx, jobs.Job{
			Service: jobs.Radarr, QueueID: int64(index + 100), Title: sample.title,
			CollectionError: sample.error, Evidence: json.RawMessage(sample.evidence),
		})
		if err != nil {
			t.Fatal(err)
		}
		job.State, job.Plan = jobs.Blocked, json.RawMessage(sample.plan)
		if err := fixture.store.FinishPlanning(ctx, job); err != nil {
			t.Fatal(err)
		}
	}

	const filter = "view=activity&state=blocked"
	listed := fixture.listJobs(t, filter)
	if len(listed) != 3 {
		t.Fatalf("blocked jobs: %+v", listed)
	}
	movie := fixture.listJobs(t, filter+"&q=incomplete_download")
	if len(movie) != 1 || movie[0].Title != "unfinished movie" || movie[0].Status != "Waiting for download" {
		t.Fatalf("search by inspection problem: %+v", movie)
	}
	album := fixture.listJobs(t, filter+"&q=mObY")
	if len(album) != 1 || album[0].Subject != "Moby — All Visible Objects" || !strings.Contains(album[0].Explanation, "These remixes do not match") {
		t.Fatalf("search by media identity: %+v", album)
	}
	if missing := fixture.listJobs(t, filter+"&q=missing-title"); len(missing) != 0 {
		t.Fatalf("unexpected match: %+v", missing)
	}
}

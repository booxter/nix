package repairui

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

const releaseEvidence = `{"case":{"releases":[{"release_id":12,"title":"Album","format":"CD","labels":["Label"]}],"capabilities":[{"action":"import_missing_tracks_v1","capability_id":"cap","release_id":12}]}}`

func addInboxJob(t *testing.T, fixture *fixture, id int64, title string, state jobs.State, reason, collectionError string) jobs.Job {
	t.Helper()
	job, err := fixture.store.Observe(context.Background(), jobs.Job{
		Service: jobs.Lidarr, QueueID: id, Title: title, SourceFingerprint: "case-a",
		Evidence: json.RawMessage(releaseEvidence), CollectionError: collectionError,
	})
	if err != nil {
		t.Fatal(err)
	}
	job.State = state
	job.Plan, err = json.Marshal(decision{Action: "no_repair", Reason: reason, Explanation: "The edition is uncertain."})
	if err != nil {
		t.Fatal(err)
	}
	if err := fixture.store.FinishPlanning(context.Background(), job); err != nil {
		t.Fatal(err)
	}
	return job
}

func TestInboxOnlyContainsCurrentUserActions(t *testing.T) {
	fixture := newFixture(t)
	addInboxJob(t, fixture, 100, "Choose my release", jobs.Blocked, "ambiguous_release", "")
	addInboxJob(t, fixture, 101, "Incomplete download", jobs.Blocked, "ambiguous_release", "incomplete_download")
	addInboxJob(t, fixture, 102, "Technical problem", jobs.Blocked, "ambiguous_release", "invalid_cue_sheet")
	addInboxJob(t, fixture, 103, "Missing audio", jobs.Blocked, "incomplete_release", "")
	addInboxJob(t, fixture, 104, "Already processing", jobs.Ready, "ambiguous_release", "")
	pending := addInboxJob(t, fixture, 105, "Already answered", jobs.Blocked, "ambiguous_release", "")
	if err := fixture.store.RequestAction(context.Background(), pending.ID, jobs.Reconsider, "use CD", 0, time.Now()); err != nil {
		t.Fatal(err)
	}
	response := fixture.get("/")
	body := response.Body.String()
	if response.Code != http.StatusOK || !strings.Contains(body, "Choose my release") ||
		!strings.Contains(body, "Use this release") || !strings.Contains(body, "Label") {
		t.Fatalf("missing actionable form: %d %s", response.Code, body)
	}
	for _, title := range []string{"Incomplete download", "Technical problem", "Missing audio", "Already processing", "Already answered"} {
		if strings.Contains(body, title) {
			t.Errorf("inbox includes non-actionable item %q", title)
		}
		if !strings.Contains(fixture.get("/activity").Body.String(), title) {
			t.Errorf("activity lost %q", title)
		}
	}
}

func inboxRequest(t *testing.T, fixture *fixture, job jobs.Job, values url.Values) *http.Request {
	t.Helper()
	page := fixture.get("/")
	if page.Code != http.StatusOK {
		t.Fatalf("inbox: %d %s", page.Code, page.Body.String())
	}
	cookie := page.Result().Cookies()[0]
	values.Set("csrf_token", cookie.Value)
	values.Set("revision", fmt.Sprint(job.Revision))
	values.Set("fingerprint", job.SourceFingerprint)
	request := httptest.NewRequest(http.MethodPost, fmt.Sprintf("/jobs/%d/respond", job.ID), strings.NewReader(values.Encode()))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Origin", "https://repairr.home.arpa")
	request.AddCookie(cookie)
	return request
}

func TestAnswerQueuesOneReviewAndLeavesInbox(t *testing.T) {
	fixture := newFixture(t)
	job := addInboxJob(t, fixture, 100, "Choose my release", jobs.Blocked, "ambiguous_release", "")
	request := inboxRequest(t, fixture, job, url.Values{"selection": {"12"}})
	duplicate := inboxRequest(t, fixture, job, url.Values{"selection": {"12"}})
	response := httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, request)
	if response.Code != http.StatusSeeOther || !strings.HasPrefix(response.Header().Get("Location"), "/?submitted=") {
		t.Fatalf("answer did not return to inbox: %d %s", response.Code, response.Body.String())
	}
	current, err := fixture.store.Get(context.Background(), job.ID)
	if err != nil || current.PendingAction != jobs.Reconsider || current.State != jobs.Observed ||
		!strings.Contains(current.Guidance, "release 12") || !strings.Contains(current.Guidance, "accept uncertainty") || len(fixture.wakes) != 1 {
		t.Fatalf("answer not persisted: %+v, %v", current, err)
	}
	if strings.Contains(fixture.get("/").Body.String(), "Choose my release") {
		t.Fatal("answered item remains in inbox")
	}
	response = httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, duplicate)
	if response.Code != http.StatusConflict || len(fixture.wakes) != 1 {
		t.Fatalf("duplicate answer queued another review: %d", response.Code)
	}
}

func TestInboxRejectsUnavailableChoicesAndStaleEvidence(t *testing.T) {
	for _, scenario := range []string{"unknown choice", "new evidence", "cross-site"} {
		t.Run(scenario, func(t *testing.T) {
			fixture := newFixture(t)
			job := addInboxJob(t, fixture, 100, "Choose my release", jobs.Blocked, "ambiguous_release", "")
			choice := "12"
			want := http.StatusConflict
			if scenario == "unknown choice" {
				choice, want = "999", http.StatusBadRequest
			}
			request := inboxRequest(t, fixture, job, url.Values{"selection": {choice}})
			if scenario == "new evidence" {
				job.SourceFingerprint = "case-b"
				if _, err := fixture.store.Observe(context.Background(), job); err != nil {
					t.Fatal(err)
				}
			}
			if scenario == "cross-site" {
				request.Header.Set("Origin", "https://other.invalid")
				want = http.StatusForbidden
			}
			response := httptest.NewRecorder()
			fixture.handler.ServeHTTP(response, request)
			if response.Code != want || len(fixture.wakes) != 0 {
				t.Fatalf("invalid answer accepted: %d %s", response.Code, response.Body.String())
			}
		})
	}
}

func TestUnansweredQuestionSurvivesReturningInputs(t *testing.T) {
	fixture := newFixture(t)
	ctx := context.Background()
	job, err := fixture.store.Observe(ctx, jobs.Job{
		Service: jobs.Lidarr, QueueID: 100, Title: "Edition question", SourceFingerprint: "case-a",
		PlanningFingerprint: "files-a", Evidence: json.RawMessage(releaseEvidence),
	})
	if err != nil {
		t.Fatal(err)
	}
	job.State = jobs.Blocked
	job.Plan = json.RawMessage(`{"action":"no_repair","reason":"ambiguous_release","explanation":"Choose the edition."}`)
	if err := fixture.store.FinishPlanning(ctx, job); err != nil {
		t.Fatal(err)
	}
	job.PlanningFingerprint, job.SourceFingerprint = "files-b", "case-b"
	if _, err := fixture.store.Observe(ctx, job); err != nil {
		t.Fatal(err)
	}
	job.PlanningFingerprint, job.SourceFingerprint = "files-a", "case-a-again"
	if _, err := fixture.store.Observe(ctx, job); err != nil {
		t.Fatal(err)
	}
	response := fixture.get("/")
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "Use this release") {
		t.Fatalf("history lost unanswered question: %d %s", response.Code, response.Body.String())
	}
}

func TestAnswerRequiresExplicitRuntimeConsentAndPreservesRetryInstructions(t *testing.T) {
	job := jobs.Job{Service: jobs.Radarr, Guidance: "use the longer cut", RuntimeToleranceMS: 1200000}
	request := httptest.NewRequest(http.MethodPost, "/", nil)
	guidance, tolerance, err := responseGuidance(request, job, attention{Kind: "retry"})
	if err != nil || guidance != job.Guidance || tolerance != job.RuntimeToleranceMS {
		t.Fatalf("retry discarded operator instructions: %q %d %v", guidance, tolerance, err)
	}
	question := attention{Kind: "runtime", AllowRuntime: true, RequireGuidance: true}
	request.PostForm = url.Values{"guidance": {"I accept the shorter edition"}, "runtime_minutes": {"20"}}
	if _, _, err := responseGuidance(request, job, question); err == nil {
		t.Fatal("runtime override accepted without explicit consent")
	}
	request.PostForm.Set("override_runtime_difference", "on")
	guidance, tolerance, err = responseGuidance(request, job, question)
	if err != nil || tolerance != 1200000 || guidance != "I accept the shorter edition" {
		t.Fatalf("runtime answer lost: %q %d %v", guidance, tolerance, err)
	}
	request.PostForm.Set("guidance", "")
	if _, _, err := responseGuidance(request, job, question); err == nil {
		t.Fatal("empty answer bought another review")
	}
}

package repairui

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
)

const releaseEvidence = `{"case":{"releases":[{"release_id":12,"title":"Album","format":"CD","labels":["Label"]}],"capabilities":[{"action":"import_missing_tracks_v1","capability_id":"cap","release_id":12}]}}`

func testInputs(_ jobs.Service, evidence json.RawMessage) (planning.Inputs, error) {
	return planning.NewInputs(struct {
		Evidence json.RawMessage `json:"evidence"`
	}{Evidence: evidence})
}

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
	result := planning.Result{Outcome: planning.Decline}
	if reason == "ambiguous_release" {
		result = planning.Result{Outcome: planning.AskOperator, Question: &planning.Question{
			Kind: planning.ChooseRelease, Title: "Choose a release", Text: "Which edition should be imported?",
			Button: "Use this release", Choices: []planning.Choice{{Value: "12", Label: "CD (Label)"}},
		}}
	}
	job.PlanResult = &result
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
	if err := fixture.store.RequestReconsideration(context.Background(), pending, planning.Answer{Guidance: "use CD"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	response := fixture.get("/")
	body := response.Body.String()
	if response.Code != http.StatusOK || !strings.Contains(body, "Choose my release") {
		t.Fatalf("missing actionable release: %d %s", response.Code, body)
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

func (fixture *fixture) actionRequest(t *testing.T, jobID int64, action string, input actionRequest) *http.Request {
	t.Helper()
	path := fmt.Sprintf("/api/jobs/%d", jobID)
	response := fixture.get(path)
	var current jobResponse
	if err := json.Unmarshal(response.Body.Bytes(), &current); err != nil || !current.Actions[action] {
		t.Fatalf("job does not offer %s: %d %s", action, response.Code, response.Body)
	}
	input.Revision, input.Fingerprint = &current.Revision, &current.Fingerprint
	body, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(http.MethodPost, path+"/"+action, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Origin", "https://repairr.home.arpa")
	request.Header.Set("X-CSRF-Token", current.CSRFToken)
	for _, cookie := range response.Result().Cookies() {
		request.AddCookie(cookie)
	}
	return request
}

func TestAnswerQueuesOneReviewAndLeavesInbox(t *testing.T) {
	fixture := newFixture(t)
	job := addInboxJob(t, fixture, 100, "Choose my release", jobs.Blocked, "ambiguous_release", "")
	note := "Keep the original track order."
	answer := actionRequest{Choice: "12", Guidance: note}
	request := fixture.actionRequest(t, job.ID, "answer", answer)
	duplicate := fixture.actionRequest(t, job.ID, "answer", answer)
	response := httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("submit answer: %d %s", response.Code, response.Body)
	}
	current, err := fixture.store.Get(context.Background(), job.ID)
	if err != nil || current.PendingAction != jobs.Reconsider || current.State != jobs.Observed ||
		current.SelectedReleaseID != 12 || current.Guidance != note || len(fixture.wakes) != 1 {
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
	for _, scenario := range []string{"unknown choice", "new evidence", "cross-site", "missing token", "missing cookie"} {
		t.Run(scenario, func(t *testing.T) {
			fixture := newFixture(t)
			job := addInboxJob(t, fixture, 100, "Choose my release", jobs.Blocked, "ambiguous_release", "")
			answer := actionRequest{Choice: "12"}
			want := http.StatusConflict
			if scenario == "unknown choice" {
				answer.Choice = "999"
				want = http.StatusBadRequest
			}
			request := fixture.actionRequest(t, job.ID, "answer", answer)
			switch scenario {
			case "new evidence":
				job.SourceFingerprint = "case-b"
				if _, err := fixture.store.Observe(context.Background(), job); err != nil {
					t.Fatal(err)
				}
			case "cross-site":
				request.Header.Set("Origin", "https://other.invalid")
				want = http.StatusForbidden
			case "missing token":
				request.Header.Del("X-CSRF-Token")
				want = http.StatusForbidden
			case "missing cookie":
				request.Header.Del("Cookie")
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
	job := addInboxJob(t, fixture, 100, "Edition question", jobs.Blocked, "ambiguous_release", "")
	job.SourceFingerprint = "case-b"
	job.Evidence = json.RawMessage(`{"case":{"releases":[]}}`)
	if _, err := fixture.store.Observe(ctx, job); err != nil {
		t.Fatal(err)
	}
	job.SourceFingerprint = "case-a-again"
	job.Evidence = json.RawMessage(releaseEvidence)
	if _, err := fixture.store.Observe(ctx, job); err != nil {
		t.Fatal(err)
	}
	response := fixture.get(fmt.Sprintf("/api/jobs/%d/question", job.ID))
	var saved jobResponse
	if err := json.Unmarshal(response.Body.Bytes(), &saved); err != nil {
		t.Fatal(err)
	}
	if response.Code != http.StatusOK || saved.Question == nil || saved.Question.Text != "Which edition should be imported?" {
		t.Fatalf("history lost unanswered question: %d %s", response.Code, response.Body.String())
	}
}

func TestRuntimeQuestionAndRetryKeepTheChosenFile(t *testing.T) {
	fixture := newFixture(t)
	ctx := context.Background()
	job, err := fixture.store.Observe(ctx, jobs.Job{
		Service: jobs.Radarr, QueueID: 100,
		Evidence: json.RawMessage(`{"case":{"radarr":{"movie":{"runtime_minutes":90}},"capabilities":[{"action":"manual_import_file_v1","file_id":"file_a"}]}}`),
		Answer:   planning.Answer{SelectedFileID: "file_a"},
	})
	if err != nil {
		t.Fatal(err)
	}
	job.State, job.Outcome = jobs.Blocked, jobs.OutcomeRuntimeMismatch
	if err := fixture.store.FinishPlanning(ctx, job); err != nil {
		t.Fatal(err)
	}
	note := "I accept the shorter edition."
	answer := actionRequest{Guidance: note}
	submit := func(want int) {
		t.Helper()
		response := httptest.NewRecorder()
		fixture.handler.ServeHTTP(response, fixture.actionRequest(t, job.ID, "answer", answer))
		if response.Code != want {
			t.Fatalf("answer returned %d, want %d: %s", response.Code, want, response.Body)
		}
	}
	submit(http.StatusBadRequest)
	minutes := int64(20)
	answer.RuntimeMinutes = &minutes
	answer.Guidance = ""
	submit(http.StatusBadRequest)
	answer.Guidance = note
	submit(http.StatusNoContent)

	job, err = fixture.store.Get(ctx, job.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := planning.Answer{SelectedFileID: "file_a", Guidance: note, RuntimeToleranceMS: 1_200_000}
	if job.Answer != want {
		t.Fatalf("runtime answer: %+v", job.Answer)
	}
	job.State, job.Outcome = jobs.Blocked, jobs.OutcomePlannerFailed
	if err := fixture.store.FinishPlanning(ctx, job); err != nil {
		t.Fatal(err)
	}
	answer = actionRequest{}
	submit(http.StatusNoContent)
	retried, err := fixture.store.Get(ctx, job.ID)
	if err != nil || retried.Answer != want {
		t.Fatalf("retry lost the operator answer: %+v, %v", retried.Answer, err)
	}
}

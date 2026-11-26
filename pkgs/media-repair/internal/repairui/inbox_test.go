package repairui

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"golang.org/x/net/html"
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

func attributes(node *html.Node) map[string]string {
	values := make(map[string]string, len(node.Attr))
	for _, attr := range node.Attr {
		values[attr.Key] = attr.Val
	}
	return values
}

// Include the hidden fields from the page and the first offered choice.
func answerFields(form *html.Node) url.Values {
	values := url.Values{}
	for field := range form.Descendants() {
		attrs := attributes(field)
		name := attrs["name"]
		if _, disabled := attrs["disabled"]; disabled || name == "" {
			continue
		}
		switch field.Data {
		case "input":
			if attrs["type"] == "hidden" {
				values.Set(name, attrs["value"])
			}
		case "select":
			for option := range field.ChildNodes() {
				choice := attributes(option)
				if _, disabled := choice["disabled"]; option.Data == "option" && !disabled {
					values.Set(name, choice["value"])
					break
				}
			}
		}
	}
	return values
}

func inboxRequest(t *testing.T, fixture *fixture, answer url.Values) *http.Request {
	t.Helper()
	page := fixture.get("/")
	if page.Code != http.StatusOK {
		t.Fatalf("inbox: %d %s", page.Code, page.Body.String())
	}
	document, err := html.Parse(page.Body)
	if err != nil {
		t.Fatal(err)
	}
	for form := range document.Descendants() {
		formAttrs := attributes(form)
		if form.Data != "form" || !strings.EqualFold(formAttrs["method"], "post") {
			continue
		}
		values := answerFields(form)
		for name := range answer {
			values.Set(name, answer.Get(name))
		}
		request := httptest.NewRequest(http.MethodPost, formAttrs["action"], strings.NewReader(values.Encode()))
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		request.Header.Set("Origin", "https://repairr.home.arpa")
		for _, cookie := range page.Result().Cookies() {
			request.AddCookie(cookie)
		}
		return request
	}
	t.Fatal("inbox has no answer form")
	return nil
}

func TestAnswerQueuesOneReviewAndLeavesInbox(t *testing.T) {
	fixture := newFixture(t)
	job := addInboxJob(t, fixture, 100, "Choose my release", jobs.Blocked, "ambiguous_release", "")
	note := "Keep the original track order."
	request := inboxRequest(t, fixture, url.Values{"guidance": {note}})
	duplicate := inboxRequest(t, fixture, nil)
	response := httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, request)
	if response.Code != http.StatusSeeOther || !strings.HasPrefix(response.Header().Get("Location"), "/?submitted=") {
		t.Fatalf("answer did not return to inbox: %d %s", response.Code, response.Body.String())
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
	for _, scenario := range []string{"unknown choice", "new evidence", "cross-site"} {
		t.Run(scenario, func(t *testing.T) {
			fixture := newFixture(t)
			job := addInboxJob(t, fixture, 100, "Choose my release", jobs.Blocked, "ambiguous_release", "")
			answer := url.Values{}
			want := http.StatusConflict
			if scenario == "unknown choice" {
				answer.Set("selection", "999")
				want = http.StatusBadRequest
			}
			request := inboxRequest(t, fixture, answer)
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
	response := fixture.get("/")
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "Which edition should be imported?") {
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
	answer := url.Values{"guidance": {note}, "runtime_minutes": {"20"}, "override_runtime_difference": {""}}
	submit := func(want int) {
		t.Helper()
		response := httptest.NewRecorder()
		fixture.handler.ServeHTTP(response, inboxRequest(t, fixture, answer))
		if response.Code != want {
			t.Fatalf("answer returned %d, want %d: %s", response.Code, want, response.Body)
		}
	}
	submit(http.StatusBadRequest)
	answer.Set("override_runtime_difference", "on")
	answer.Set("guidance", "")
	submit(http.StatusBadRequest)
	answer.Set("guidance", note)
	submit(http.StatusSeeOther)

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
	answer = nil
	submit(http.StatusSeeOther)
	retried, err := fixture.store.Get(ctx, job.ID)
	if err != nil || retried.Answer != want {
		t.Fatalf("retry lost the operator answer: %+v, %v", retried.Answer, err)
	}
}

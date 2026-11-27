package repairui

import (
	"encoding/json"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

func TestPresentationPrioritizesCurrentState(t *testing.T) {
	stalePlan := json.RawMessage(`{"action":"no_repair","explanation":"Old decision"}`)
	tests := []struct {
		name   string
		job    jobs.Job
		status string
	}{
		{"collection failure", jobs.Job{State: jobs.Blocked, CollectionError: "incomplete_download", Plan: stalePlan}, "Waiting for download"},
		{"unknown collection failure", jobs.Job{State: jobs.Blocked, CollectionError: "permission denied", Plan: stalePlan}, "Could not inspect"},
		{"queue eligibility", jobs.Job{State: jobs.Blocked, CollectionError: "Lidarr queue item is not eligible for repair", Plan: stalePlan}, "Queue not ready"},
		{"execution failure", jobs.Job{State: jobs.Failed, Reason: "execution failed", Plan: stalePlan}, "Failed"},
		{"changed evidence", jobs.Job{State: jobs.Blocked, Reason: "current Lidarr import bindings changed after planning", Plan: stalePlan}, "Evidence changed"},
		{"pending removal", jobs.Job{State: jobs.Blocked, PendingAction: jobs.Delete, CollectionError: "incomplete_download", Plan: stalePlan}, "Removal requested"},
		{"planner fallback", jobs.Job{State: jobs.Blocked, Plan: json.RawMessage(`{"action":"no_repair","explanation":"The planner could not produce a valid decision within its attempt limit."}`)}, "Planner failed"},
		{"fallback reappeared", jobs.Job{State: jobs.Blocked, Reason: "queue entry is present again", Plan: json.RawMessage(`{"action":"no_repair","explanation":"The planner could not produce a valid decision within its attempt limit."}`)}, "Planner failed"},
		{"reconsider waiting", jobs.Job{State: jobs.Blocked, PendingAction: jobs.Reconsider, CollectionError: "incomplete_download"}, "Waiting for download"},
		{"decision", jobs.Job{State: jobs.Blocked, Plan: stalePlan}, "No automatic repair chosen"},
		{"imported with old error", jobs.Job{State: jobs.Imported, CollectionError: "incomplete_download", Plan: stalePlan}, "Imported"},
		{"coded queue state", jobs.Job{State: jobs.Blocked, CollectionError: "different wording", CollectionOutcome: jobs.OutcomeQueueNotReady}, "Queue not ready"},
		{"coded changed evidence", jobs.Job{State: jobs.Blocked, Outcome: jobs.OutcomeEvidenceChanged, Reason: "different wording", Plan: stalePlan}, "Evidence changed"},
		{"coded planner failure", jobs.Job{State: jobs.Blocked, Plan: json.RawMessage(`{"action":"no_repair","reason":"planner_failed","explanation":"different wording"}`)}, "Planner failed"},
		{"coded ordinary failure", jobs.Job{State: jobs.Blocked, Outcome: jobs.OutcomeOther, Reason: "context canceled in unrelated text"}, "Blocked"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := present(tt.job)
			if got.Status != tt.status {
				t.Fatalf("got status %q, want %q", got.Status, tt.status)
			}
		})
	}
}

func TestPresentationIdentity(t *testing.T) {
	tests := []struct {
		evidence string
		want     string
	}{
		{`{"Case":{"album":{"artist":"Artist","title":"Album"}}}`, "Artist — Album"},
		{`{"Case":{"radarr":{"movie":{"title":"Movie","year":2020}}}}`, "Movie (2020)"},
		{`{"Case":{"radarr":{"movie":{"title":"Unknown year"}}}}`, "Unknown year"},
		{`invalid`, "Queue title"},
	}
	for _, tt := range tests {
		got := present(jobs.Job{Title: "Queue title", Evidence: json.RawMessage(tt.evidence)})
		if got.Subject != tt.want {
			t.Errorf("evidence %s: got subject %q, want %q", tt.evidence, got.Subject, tt.want)
		}
	}
}

func TestPresentationKeepsRepairFailureVisible(t *testing.T) {
	for _, state := range []jobs.State{jobs.Blocked, jobs.Failed} {
		t.Run(string(state), func(t *testing.T) {
			job := jobs.Job{
				State: state, InQueue: true, Reason: "decision rejected: technical_checks_rejected",
				Plan: json.RawMessage(`{"action":"join_parts_v1","explanation":"Join both parts"}`),
			}
			view := present(job)
			if view.Explanation != job.Reason || !view.Actions["reconsider"] {
				t.Fatalf("failure lost its explanation or actions: %+v", view)
			}
		})
	}
}

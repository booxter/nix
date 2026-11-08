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
		group  string
	}{
		{"collection failure", jobs.Job{State: jobs.Blocked, CollectionError: "incomplete_download", Plan: stalePlan}, "Waiting for download", "waiting"},
		{"unknown collection failure", jobs.Job{State: jobs.Blocked, CollectionError: "permission denied", Plan: stalePlan}, "Could not inspect", "inspection"},
		{"queue eligibility", jobs.Job{State: jobs.Blocked, CollectionError: "Lidarr queue item is not eligible for repair", Plan: stalePlan}, "Queue not ready", "waiting"},
		{"execution failure", jobs.Job{State: jobs.Failed, Reason: "execution failed", Plan: stalePlan}, "Failed", "review"},
		{"changed evidence", jobs.Job{State: jobs.Blocked, Reason: "current Lidarr import bindings changed after planning", Plan: stalePlan}, "Evidence changed", "changed"},
		{"pending removal", jobs.Job{State: jobs.Blocked, PendingAction: jobs.Delete, CollectionError: "incomplete_download", Plan: stalePlan}, "Removal requested", "removal"},
		{"planner fallback", jobs.Job{State: jobs.Blocked, Plan: json.RawMessage(`{"action":"no_repair","explanation":"The planner could not produce a valid decision within its attempt limit."}`)}, "Planner failed", "planner"},
		{"fallback reappeared", jobs.Job{State: jobs.Blocked, Reason: "queue entry is present again", Plan: json.RawMessage(`{"action":"no_repair","explanation":"The planner could not produce a valid decision within its attempt limit."}`)}, "Planner failed", "planner"},
		{"reconsider waiting", jobs.Job{State: jobs.Blocked, PendingAction: jobs.Reconsider, CollectionError: "incomplete_download"}, "Waiting for download", "waiting"},
		{"decision", jobs.Job{State: jobs.Blocked, Plan: stalePlan}, "No automatic repair chosen", "decision"},
		{"imported with old error", jobs.Job{State: jobs.Imported, CollectionError: "incomplete_download", Plan: stalePlan}, "Imported", "review"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := present(tt.job)
			if got.Status != tt.status || got.Group != tt.group {
				t.Fatalf("got status %q and group %q", got.Status, got.Group)
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
			if view.Explanation != job.Reason || !view.CanAct {
				t.Fatalf("failure lost its explanation or actions: %+v", view)
			}
		})
	}
}

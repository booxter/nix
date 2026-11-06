package repairui

import (
	"encoding/json"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

func TestAttentionClassification(t *testing.T) {
	lidarrEvidence := json.RawMessage(`{"case":{"releases":[{"release_id":12,"title":"Album","format":"CD"},{"release_id":13,"title":"Other"}],"capabilities":[{"action":"import_missing_tracks_v1","capability_id":"cap","release_id":12}]}}`)
	radarrEvidence := json.RawMessage(`{"case":{"radarr":{"movie":{"title":"Movie","runtime_minutes":90}},"files":[{"file_id":"a","path_components":["a.mkv"]},{"file_id":"b","path_components":["b.mkv"]}],"capabilities":[{"action":"manual_import_file_v1","capability_id":"cap-a","file_id":"a"},{"action":"manual_import_file_v1","capability_id":"cap-b","file_id":"b"},{"action":"join_parts_v1","capability_id":"join","candidate_file_ids":["a","b"]}]}}`)

	tests := []struct {
		name    string
		job     jobs.Job
		plan    decision
		kind    string
		choices int
	}{
		{"legacy fallback", jobs.Job{Evidence: lidarrEvidence}, decision{Explanation: plannerFallback}, "retry", 0},
		{"interrupted", jobs.Job{Evidence: lidarrEvidence, State: jobs.Failed, Reason: "repair interrupted before import; reconsider to retry"}, decision{}, "retry", 0},
		{"runtime gate", jobs.Job{Service: jobs.Radarr, Evidence: radarrEvidence, Reason: "decision rejected: runtime_mismatch"}, decision{}, "runtime", 0},
		{"runtime without evidence", jobs.Job{Service: jobs.Radarr, Reason: "decision rejected: runtime_mismatch"}, decision{}, "", 0},
		{"retry without evidence", jobs.Job{}, decision{Explanation: plannerFallback}, "", 0},
		{"release", jobs.Job{Service: jobs.Lidarr, Evidence: lidarrEvidence}, decision{Action: "no_repair", Reason: "ambiguous_release"}, "release", 1},
		{"tracks", jobs.Job{Service: jobs.Lidarr, Evidence: lidarrEvidence}, decision{Action: "no_repair", Reason: "ambiguous_tracks"}, "guidance", 0},
		{"files", jobs.Job{Service: jobs.Radarr, Evidence: radarrEvidence}, decision{Action: "no_repair", Reason: "ambiguous_file_selection"}, "file", 2},
		{"parts", jobs.Job{Service: jobs.Radarr, Evidence: radarrEvidence}, decision{Action: "no_repair", Reason: "ambiguous_part_order"}, "guidance", 0},
		{"missing runtime", jobs.Job{Service: jobs.Radarr, Evidence: radarrEvidence}, decision{Action: "no_repair", Reason: "insufficient_evidence", MissingEvidence: []string{"movie_runtime"}}, "guidance", 0},
		{"technical evidence", jobs.Job{Service: jobs.Radarr, Evidence: radarrEvidence}, decision{Action: "no_repair", Reason: "insufficient_evidence", MissingEvidence: []string{"movie_runtime", "media_probe"}}, "", 0},
		{"missing case", jobs.Job{Service: jobs.Lidarr}, decision{Action: "no_repair", Reason: "ambiguous_release"}, "", 0},
		{"stale decision", jobs.Job{Service: jobs.Lidarr, Evidence: lidarrEvidence, Reason: "current Lidarr import bindings changed after planning"}, decision{Action: "no_repair", Reason: "ambiguous_release"}, "", 0},
		{"collection error", jobs.Job{CollectionError: "waiting for evidence"}, decision{Explanation: plannerFallback}, "", 0},
		{"pending", jobs.Job{PendingAction: jobs.Reconsider}, decision{Explanation: plannerFallback}, "", 0},
		{"ready", jobs.Job{State: jobs.Ready}, decision{Explanation: plannerFallback}, "", 0},
		{"ordinary decline", jobs.Job{Service: jobs.Radarr, Evidence: radarrEvidence}, decision{Action: "no_repair", Reason: "no_repair_needed"}, "", 0},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			test.job.InQueue = true
			if test.job.State == "" {
				test.job.State = jobs.Blocked
			}
			got := attentionFor(test.job, test.plan)
			if test.kind == "" {
				if got != nil {
					t.Fatalf("unexpected attention: %+v", got)
				}
				return
			}
			if got == nil || got.Kind != test.kind || len(got.Choices) != test.choices {
				t.Fatalf("attention = %+v, want %s with %d choices", got, test.kind, test.choices)
			}
			if test.name == "missing runtime" && !got.AllowRuntime {
				t.Fatal("runtime input not offered")
			}
		})
	}
}

func TestInboxDoesNotOfferInstructionsForUnavailableOperations(t *testing.T) {
	evidence := json.RawMessage(`{"Case":{"radarr":{"movie":{"title":"Movie"}},"capabilities":[{"action":"manual_import_file_v1","file_id":"a"}]}}`)
	for _, plan := range []decision{
		{Action: "no_repair", Reason: "ambiguous_part_order"},
		{Action: "no_repair", Reason: "insufficient_evidence", MissingEvidence: []string{"part_membership"}},
		{Action: "no_repair", Reason: "insufficient_evidence", MissingEvidence: []string{"disc_playlist"}},
		{Action: "no_repair", Reason: "insufficient_evidence", MissingEvidence: []string{"movie_runtime"}},
	} {
		job := jobs.Job{Service: jobs.Radarr, State: jobs.Blocked, InQueue: true, Evidence: evidence}
		if got := attentionFor(job, plan); got != nil {
			t.Fatalf("offered impossible action for %+v: %+v", plan, got)
		}
	}
}

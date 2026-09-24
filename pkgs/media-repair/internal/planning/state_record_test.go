package planning

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

const resultTestCaseID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func TestStoredResultReadsLegacyVersions(t *testing.T) {
	t.Parallel()
	for _, version := range []string{legacyRadarrResultVersion, legacyLidarrResultVersion} {
		version := version
		t.Run(version, func(t *testing.T) {
			t.Parallel()
			data := []byte(`{"version":"` + version + `","case_id":"` + resultTestCaseID +
				`","attempts":1,"attempted_at":"2026-09-24T12:00:00Z","decision":{"case_id":"` +
				resultTestCaseID + `"}}`)
			result, err := DecodeStoredResult(data, resultTestDecision)
			if err != nil || !result.HasDecision() {
				t.Fatalf("result = %#v, error = %v", result, err)
			}
		})
	}
}

func TestStoredResultDecisionIsTerminal(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	decision := json.RawMessage(`{"case_id":"` + resultTestCaseID + `"}`)
	first, changed, err := NextDecision(StoredResult{}, false, resultTestCaseID, decision, now)
	if err != nil || !changed {
		t.Fatalf("first = %#v, changed = %t, error = %v", first, changed, err)
	}
	second, changed, err := NextDecision(first, true, resultTestCaseID, decision, now.Add(time.Minute))
	if err != nil || changed || second.Attempts != 1 {
		t.Fatalf("second = %#v, changed = %t, error = %v", second, changed, err)
	}
	_, changed, err = NextDecision(
		first, true, resultTestCaseID, json.RawMessage(`{"case_id":"different"}`), now,
	)
	if err == nil || changed || !strings.Contains(err.Error(), "different planning decision") {
		t.Fatalf("changed = %t, error = %v", changed, err)
	}
}

func resultTestDecision(data json.RawMessage) (string, json.RawMessage, error) {
	var decision struct {
		CaseID string `json:"case_id"`
	}
	if err := json.Unmarshal(data, &decision); err != nil {
		return "", nil, err
	}
	canonical, err := json.Marshal(decision)
	return decision.CaseID, canonical, err
}

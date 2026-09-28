package reconsideration

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/planning"
)

func TestResultStoreKeepsOneTerminalDecisionPerRequest(t *testing.T) {
	request := testRequest(
		t,
		"Keep the first decision unless the files prove it wrong.",
		time.Date(2026, 9, 27, 13, 0, 0, 0, time.UTC),
	)
	store, err := NewResultStore(t.TempDir(), testDecision)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 27, 14, 0, 0, 0, time.UTC)
	decision := json.RawMessage(fmt.Sprintf(`{"case_id":%q,"answer":"first"}`, request.CaseID))

	stored, changed, err := store.PutDecision(request, decision, now)
	if err != nil {
		t.Fatal(err)
	}
	if !changed || !stored.Status().Decided || stored.RequestID != request.RequestID {
		t.Fatalf("unexpected stored result: %#v changed=%v", stored, changed)
	}

	loaded, found, err := store.Get(request)
	if err != nil || !found || string(loaded.Outcome.Decision) != string(decision) {
		t.Fatalf("unexpected loaded result: %#v found=%v err=%v", loaded, found, err)
	}
	_, changed, err = store.PutDecision(request, decision, now.Add(time.Minute))
	if err != nil || changed {
		t.Fatalf("identical decision was not idempotent: changed=%v err=%v", changed, err)
	}
	other := json.RawMessage(fmt.Sprintf(`{"case_id":%q,"answer":"other"}`, request.CaseID))
	if _, _, err := store.PutDecision(request, other, now.Add(time.Minute)); err == nil {
		t.Fatal("different terminal decision was accepted")
	}
}

func TestResultStoreRetriesFailureWithoutReplacingPriorRequest(t *testing.T) {
	first := testRequest(
		t,
		"Consider the first explanation.",
		time.Date(2026, 9, 27, 13, 0, 0, 0, time.UTC),
	)
	second := testRequest(t, "Consider the newer explanation.", first.CreatedAt.Add(time.Minute))
	store, err := NewResultStore(t.TempDir(), testDecision)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 27, 14, 0, 0, 0, time.UTC)
	failure := planning.Failure{Kind: planning.FailureUnavailable}

	if _, changed, err := store.PutFailure(first, failure, now, now.Add(time.Minute)); err != nil || !changed {
		t.Fatalf("store first failure: changed=%v err=%v", changed, err)
	}
	if _, changed, err := store.PutFailure(
		first, failure, now.Add(time.Minute), now.Add(3*time.Minute),
	); err != nil || !changed {
		t.Fatalf("retry first failure: changed=%v err=%v", changed, err)
	}
	decision := json.RawMessage(fmt.Sprintf(`{"case_id":%q,"answer":"new"}`, second.CaseID))
	if _, changed, err := store.PutDecision(second, decision, now); err != nil || !changed {
		t.Fatalf("store second decision: changed=%v err=%v", changed, err)
	}
	firstResult, _, _ := store.Get(first)
	secondResult, _, _ := store.Get(second)
	if firstResult.Outcome.Attempts != 2 || !secondResult.Outcome.HasDecision() {
		t.Fatalf("request histories were not independent: %#v %#v", firstResult, secondResult)
	}
}

func testDecision(data json.RawMessage) (string, json.RawMessage, error) {
	var value struct {
		CaseID string `json:"case_id"`
		Answer string `json:"answer"`
	}
	if err := json.Unmarshal(data, &value); err != nil {
		return "", nil, err
	}
	canonical, err := json.Marshal(value)
	return value.CaseID, canonical, err
}

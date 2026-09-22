package casestore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
)

func TestStorePlanningFailureCanBecomeDecision(t *testing.T) {
	t.Parallel()

	root := filepath.Join(t.TempDir(), "state")
	store, record := newPlanningStore(t, root)
	firstAttempt := time.Date(2026, time.September, 12, 10, 0, 0, 0, time.FixedZone("test", -4*60*60))
	firstRetry := firstAttempt.Add(5 * time.Minute)
	first, changed, err := store.PutPlanningFailure(
		record.CaseID,
		PlanningFailure{Kind: PlanningFailureTimeout},
		firstAttempt,
		firstRetry,
	)
	if err != nil || !changed {
		t.Fatalf("first failure: changed = %t, error = %v", changed, err)
	}
	if first.Attempts != 1 || first.AttemptedAt.Location() != time.UTC ||
		first.RetryAfter == nil || first.RetryAfter.Location() != time.UTC {
		t.Fatalf("unexpected first failure: %#v", first)
	}

	secondAttempt := firstRetry
	secondRetry := secondAttempt.Add(10 * time.Minute)
	second, changed, err := store.PutPlanningFailure(
		record.CaseID,
		PlanningFailure{Kind: PlanningFailureHTTP, StatusCode: 503},
		secondAttempt,
		secondRetry,
	)
	if err != nil || !changed {
		t.Fatalf("second failure: changed = %t, error = %v", changed, err)
	}
	if second.Attempts != 2 || second.Failure == nil ||
		second.Failure.Kind != PlanningFailureHTTP || second.Failure.StatusCode != 503 {
		t.Fatalf("unexpected second failure: %#v", second)
	}

	decision := planningDecision(t, record.CaseID)
	final, changed, err := store.PutPlanningDecision(record.CaseID, decision, secondRetry)
	if err != nil || !changed {
		t.Fatalf("decision: changed = %t, error = %v", changed, err)
	}
	if final.Attempts != 3 || !final.HasDecision() || final.Failure != nil || final.RetryAfter != nil {
		t.Fatalf("unexpected decision result: %#v", final)
	}

	stored, found, err := store.GetPlanningResult(record.CaseID)
	if err != nil || !found {
		t.Fatalf("get result: found = %t, error = %v", found, err)
	}
	if !reflect.DeepEqual(stored, final) {
		t.Fatalf("stored result differs:\n got: %#v\nwant: %#v", stored, final)
	}

	digest, err := caseDigest(record.CaseID)
	if err != nil {
		t.Fatal(err)
	}
	assertMode(t, filepath.Join(root, planningDirectoryName), 0o700)
	assertMode(t, filepath.Join(root, planningDirectoryName, digest+".json"), 0o600)
}

func TestStorePlanningDecisionIsTerminalAndIdempotent(t *testing.T) {
	t.Parallel()

	store, record := newPlanningStore(t, filepath.Join(t.TempDir(), "state"))
	decision := planningDecision(t, record.CaseID)
	attemptedAt := time.Date(2026, time.September, 12, 14, 0, 0, 0, time.UTC)
	first, changed, err := store.PutPlanningDecision(record.CaseID, decision, attemptedAt)
	if err != nil || !changed {
		t.Fatalf("first decision: changed = %t, error = %v", changed, err)
	}

	same, changed, err := store.PutPlanningDecision(
		record.CaseID, decision, attemptedAt.Add(time.Hour),
	)
	if err != nil || changed {
		t.Fatalf("same decision: changed = %t, error = %v", changed, err)
	}
	if !reflect.DeepEqual(same, first) {
		t.Fatal("idempotent write changed the stored decision")
	}

	afterFailure, changed, err := store.PutPlanningFailure(
		record.CaseID,
		PlanningFailure{Kind: PlanningFailureUnavailable},
		attemptedAt.Add(time.Hour),
		attemptedAt.Add(2*time.Hour),
	)
	if err != nil || changed {
		t.Fatalf("failure after decision: changed = %t, error = %v", changed, err)
	}
	if !reflect.DeepEqual(afterFailure, first) {
		t.Fatal("failure replaced the stored decision")
	}

	different := planningDecision(t, record.CaseID)
	different.NoRepair.Explanation += " Different."
	if _, changed, err := store.PutPlanningDecision(
		record.CaseID, different, attemptedAt.Add(time.Hour),
	); err == nil || changed || !strings.Contains(err.Error(), "different planning decision") {
		t.Fatalf("different decision: changed = %t, error = %v", changed, err)
	}
}

func TestStorePlanningResultRequiresStoredCase(t *testing.T) {
	t.Parallel()

	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	caseID := "sha256:" + strings.Repeat("a", 64)
	attemptedAt := time.Date(2026, time.September, 12, 14, 0, 0, 0, time.UTC)
	if _, changed, err := store.PutPlanningFailure(
		caseID,
		PlanningFailure{Kind: PlanningFailureUnexpected},
		attemptedAt,
		attemptedAt.Add(time.Minute),
	); err == nil || changed || !strings.Contains(err.Error(), "is not stored") {
		t.Fatalf("missing case: changed = %t, error = %v", changed, err)
	}
}

func TestStoreDoesNotReplaceCorruptPlanningResult(t *testing.T) {
	t.Parallel()

	store, record := newPlanningStore(t, filepath.Join(t.TempDir(), "state"))
	path, err := store.planningResultPath(record.CaseID)
	if err != nil {
		t.Fatal(err)
	}
	const corrupt = `{"not":"a planning result"}`
	if err := os.WriteFile(path, []byte(corrupt), 0o600); err != nil {
		t.Fatal(err)
	}
	attemptedAt := time.Date(2026, time.September, 12, 14, 0, 0, 0, time.UTC)
	if _, changed, err := store.PutPlanningFailure(
		record.CaseID,
		PlanningFailure{Kind: PlanningFailureUnexpected},
		attemptedAt,
		attemptedAt.Add(time.Minute),
	); err == nil || changed {
		t.Fatalf("replace corrupt result: changed = %t, error = %v", changed, err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != corrupt {
		t.Fatalf("corrupt result was replaced with %q", data)
	}
}

func TestStoreDoesNotReplaceMismatchedPlanningResult(t *testing.T) {
	t.Parallel()

	store, record := newPlanningStore(t, filepath.Join(t.TempDir(), "state"))
	path, err := store.planningResultPath(record.CaseID)
	if err != nil {
		t.Fatal(err)
	}
	attemptedAt := time.Date(2026, time.September, 12, 14, 0, 0, 0, time.UTC)
	retryAfter := attemptedAt.Add(time.Minute)
	mismatched := PlanningResult{
		Version:     PlanningResultVersionV1,
		CaseID:      "sha256:" + strings.Repeat("a", 64),
		Attempts:    1,
		AttemptedAt: attemptedAt,
		RetryAfter:  &retryAfter,
		Failure:     &PlanningFailure{Kind: PlanningFailureTimeout},
	}
	data, err := EncodePlanningResult(mismatched)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, changed, err := store.PutPlanningFailure(
		record.CaseID,
		PlanningFailure{Kind: PlanningFailureUnexpected},
		attemptedAt,
		retryAfter,
	); err == nil || changed || !strings.Contains(err.Error(), "unexpected case ID") {
		t.Fatalf("replace mismatched result: changed = %t, error = %v", changed, err)
	}
	stored, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(stored, data) {
		t.Fatal("mismatched result was replaced")
	}
}

func TestDecodePlanningResultRejectsInvalidRecords(t *testing.T) {
	t.Parallel()

	attemptedAt := time.Date(2026, time.September, 12, 14, 0, 0, 0, time.UTC)
	caseID := "sha256:" + strings.Repeat("a", 64)
	retryAfter := attemptedAt.Add(time.Minute)
	valid := PlanningResult{
		Version:     PlanningResultVersionV1,
		CaseID:      caseID,
		Attempts:    1,
		AttemptedAt: attemptedAt,
		RetryAfter:  &retryAfter,
		Failure:     &PlanningFailure{Kind: PlanningFailureTimeout},
	}
	data, err := EncodePlanningResult(valid)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodePlanningResult(data)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(decoded, valid) {
		t.Fatalf("decoded result differs:\n got: %#v\nwant: %#v", decoded, valid)
	}

	for name, mutate := range map[string]func(*PlanningResult){
		"zero attempts": func(result *PlanningResult) { result.Attempts = 0 },
		"missing retry": func(result *PlanningResult) { result.RetryAfter = nil },
		"early retry":   func(result *PlanningResult) { result.RetryAfter = &result.AttemptedAt },
		"unknown failure": func(result *PlanningResult) {
			result.Failure = &PlanningFailure{Kind: "unknown"}
		},
		"status without HTTP failure": func(result *PlanningResult) {
			result.Failure.StatusCode = 503
		},
	} {
		mutate := mutate
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			invalid := valid
			failure := *valid.Failure
			invalid.Failure = &failure
			mutate(&invalid)
			unchecked, err := json.Marshal(invalid)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := DecodePlanningResult(unchecked); err == nil {
				t.Fatal("invalid planning result decoded successfully")
			}
		})
	}
}

func newPlanningStore(t *testing.T, root string) (*Store, CaseRecord) {
	t.Helper()
	store, err := New(root)
	if err != nil {
		t.Fatal(err)
	}
	record := newRecordForTest(t)
	if created, err := store.Put(record); err != nil || !created {
		t.Fatalf("put case: created = %t, error = %v", created, err)
	}
	return store, record
}

func planningDecision(t *testing.T, caseID string) contracts.RepairDecisionV3 {
	t.Helper()
	data, err := os.ReadFile("../../contracts/v3/examples/repair-decision-no-repair.json")
	if err != nil {
		t.Fatal(err)
	}
	decision, err := contracts.DecodeDecision(data)
	if err != nil {
		t.Fatal(err)
	}
	decision.NoRepair.CaseID = caseID
	return decision
}

package planning

import (
	"context"
	"errors"
	"testing"
	"time"
)

type testCase struct {
	id    string
	local string
}

type testDecision struct {
	caseID string
}

type testClock struct {
	now time.Time
}

func (clock *testClock) Now() time.Time { return clock.now }

type testStore struct {
	cases     map[string]testCase
	statuses  map[string]Status
	decisions map[string]testDecision
}

func newTestStore() *testStore {
	return &testStore{
		cases: make(map[string]testCase), statuses: make(map[string]Status),
		decisions: make(map[string]testDecision),
	}
}

func (store *testStore) PutCase(repairCase testCase) (bool, error) {
	if _, found := store.cases[repairCase.id]; found {
		return false, nil
	}
	store.cases[repairCase.id] = repairCase
	return true, nil
}

func (store *testStore) GetStatus(caseID string) (Status, bool, error) {
	status, found := store.statuses[caseID]
	return status, found, nil
}

func (store *testStore) GetDecision(caseID string) (testDecision, error) {
	return store.decisions[caseID], nil
}

func (store *testStore) PutFailure(
	caseID string,
	_ Failure,
	_ time.Time,
	retryAfter time.Time,
) (Status, bool, error) {
	status := store.statuses[caseID]
	status.Attempts++
	status.RetryAfter = &retryAfter
	store.statuses[caseID] = status
	return status, true, nil
}

func (store *testStore) PutDecision(
	caseID string,
	decision testDecision,
	_ time.Time,
) (Status, bool, error) {
	if status := store.statuses[caseID]; status.Decided {
		return status, false, nil
	}
	status := store.statuses[caseID]
	status.Attempts++
	status.Decided = true
	status.RetryAfter = nil
	store.statuses[caseID] = status
	store.decisions[caseID] = decision
	return status, true, nil
}

func TestRunnerCachesTerminalDecisionByCase(t *testing.T) {
	t.Parallel()
	store := newTestStore()
	clock := &testClock{now: time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)}
	plans := 0
	runner := newTestRunner(t, store, clock, func(_ context.Context, repairCase testCase) (
		testDecision,
		error,
	) {
		plans++
		return testDecision{caseID: repairCase.id}, nil
	})

	first, err := runner.Process(context.Background(), testCase{id: "case:one", local: "first"})
	if err != nil || first.Outcome != Decided || !first.Stored || !first.Submitted {
		t.Fatalf("first = %#v, error = %v", first, err)
	}
	second, err := runner.Process(context.Background(), testCase{id: "case:one", local: "second"})
	if err != nil || second.Outcome != AlreadyDecided || second.Stored || second.Submitted || plans != 1 {
		t.Fatalf("second = %#v, plans = %d, error = %v", second, plans, err)
	}
	if second.Planned.Case.local != "second" {
		t.Fatalf("cached decision used stale local case data: %#v", second.Planned.Case)
	}
}

func TestRunnerDefersRetryableFailure(t *testing.T) {
	t.Parallel()
	store := newTestStore()
	now := time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)
	clock := &testClock{now: now}
	plans := 0
	runner := newTestRunner(t, store, clock, func(context.Context, testCase) (
		testDecision,
		error,
	) {
		plans++
		return testDecision{}, errors.New("planner unavailable")
	})

	first, err := runner.Process(context.Background(), testCase{id: "case:retry"})
	if err == nil || first.Outcome != Failed || first.Failure == nil ||
		first.Failure.Kind != FailureUnavailable {
		t.Fatalf("first = %#v, error = %v", first, err)
	}
	second, err := runner.Process(context.Background(), testCase{id: "case:retry"})
	if err != nil || second.Outcome != Deferred || second.Submitted || plans != 1 {
		t.Fatalf("second = %#v, plans = %d, error = %v", second, plans, err)
	}
	status := store.statuses["case:retry"]
	if status.RetryAfter == nil || !status.RetryAfter.Equal(now.Add(5*time.Minute)) {
		t.Fatalf("status = %#v", status)
	}
}

func newTestRunner(
	t *testing.T,
	store *testStore,
	clock *testClock,
	plan func(context.Context, testCase) (testDecision, error),
) *Runner[testCase, testDecision, Failure] {
	t.Helper()
	runner, err := New(Dependencies[testCase, testDecision, Failure]{
		Store: store, Plan: plan, Clock: clock,
		CaseID:         func(repairCase testCase) string { return repairCase.id },
		DecisionCaseID: func(decision testDecision) string { return decision.caseID },
		Superseded:     func(testCase) bool { return false },
		ClassifyFailure: func(error) Failure {
			return Failure{Kind: FailureUnavailable}
		},
		Backoff: Backoff{Initial: 5 * time.Minute, Maximum: 40 * time.Minute},
	})
	if err != nil {
		t.Fatal(err)
	}
	return runner
}

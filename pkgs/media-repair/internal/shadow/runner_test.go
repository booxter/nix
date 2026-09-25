package shadow

import (
	"context"
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/inspection"
)

const (
	testInitialBackoff = 5 * time.Minute
	testMaximumBackoff = 40 * time.Minute
)

func TestRunProcessesCasesAfterCollectionAndPlannerFailures(t *testing.T) {
	t.Parallel()

	firstID := testCaseID("1")
	secondID := testCaseID("2")
	thirdID := testCaseID("3")
	source := &fakeCaseSource{
		assemblies: []casebuilder.Assembly{
			testAssembly(firstID),
			testAssembly(secondID),
			testAssembly(thirdID),
		},
		err: errors.New("one queue record could not be collected"),
	}
	planner := &fakePlanner{responses: map[string]plannerResponse{
		firstID:  {decision: testDecision(t, firstID)},
		secondID: {err: errors.New("planner unavailable")},
		thirdID:  {decision: testDecision(t, thirdID)},
	}}
	store := newFakeStore()
	now := time.Date(2026, time.September, 12, 18, 0, 0, 0, time.UTC)
	runner := newTestRunner(t, source, store, planner, now)

	report, err := runner.Run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "could not be collected") ||
		!strings.Contains(err.Error(), "planner unavailable") {
		t.Fatalf("error = %v", err)
	}
	wantReport := Report{Observed: 3, Stored: 3, Submitted: 3, Decided: 2, Failed: 1}
	if !reflect.DeepEqual(reportSummary(report), wantReport) {
		t.Fatalf("report = %#v, want %#v", report, wantReport)
	}
	if !reflect.DeepEqual(planner.calls, []string{firstID, secondID, thirdID}) {
		t.Fatalf("planner calls = %v", planner.calls)
	}
	if len(store.failures) != 1 || store.failures[0].caseID != secondID ||
		store.failures[0].failure.Kind != casestore.PlanningFailureUnavailable ||
		!store.failures[0].retryAfter.Equal(now.Add(testInitialBackoff)) {
		t.Fatalf("stored failures = %#v", store.failures)
	}
	if !reflect.DeepEqual(store.decisions, []string{firstID, thirdID}) {
		t.Fatalf("stored decisions = %v", store.decisions)
	}
	assertPlannedCaseIDs(t, report.PlannedCases, []string{firstID, thirdID})
}

func TestRunReportsRejectedEvidenceWithoutFailing(t *testing.T) {
	t.Parallel()

	caseID := testCaseID("9")
	source := &fakeCaseSource{
		assemblies: []casebuilder.Assembly{testAssembly(caseID)},
		rejections: []inspection.Rejection{{
			QueueID: 71,
			Reason:  inspection.RejectionInvalidEvidence,
		}},
	}
	runner := newTestRunner(
		t,
		source,
		newFakeStore(),
		&fakePlanner{responses: map[string]plannerResponse{
			caseID: {decision: testDecision(t, caseID)},
		}},
		time.Date(2026, time.September, 12, 18, 0, 0, 0, time.UTC),
	)

	report, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := Report{Observed: 1, Rejected: 1, Stored: 1, Submitted: 1, Decided: 1}
	if !reflect.DeepEqual(reportSummary(report), want) ||
		!reflect.DeepEqual(report.Rejections, source.rejections) {
		t.Fatalf("report = %#v", report)
	}
}

func TestRunSkipsDecidedAndDeferredCases(t *testing.T) {
	t.Parallel()

	decidedID := testCaseID("4")
	deferredID := testCaseID("5")
	staleID := testCaseID("a")
	now := time.Date(2026, time.September, 12, 18, 0, 0, 0, time.UTC)
	retryAfter := now.Add(time.Minute)
	store := newFakeStore()
	store.known[decidedID] = true
	store.known[deferredID] = true
	store.known[staleID] = true
	store.assemblies[decidedID] = testAssembly(decidedID)
	store.results[decidedID] = casestore.PlanningResult{
		CaseID: decidedID, Attempts: 1, Decision: encodedTestDecision(t, decidedID),
	}
	store.results[deferredID] = casestore.PlanningResult{
		CaseID: deferredID, Attempts: 1, RetryAfter: &retryAfter,
		Failure: &casestore.PlanningFailure{Kind: casestore.PlanningFailureTimeout},
	}
	store.results[staleID] = casestore.PlanningResult{
		CaseID: staleID, Attempts: 1, Decision: encodedTestDecision(t, staleID),
	}
	source := &fakeCaseSource{assemblies: []casebuilder.Assembly{
		testAssembly(decidedID),
		testAssembly(deferredID),
	}}
	planner := &fakePlanner{}
	runner := newTestRunner(t, source, store, planner, now)

	report, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	wantReport := Report{Observed: 2, AlreadyDecided: 1, Deferred: 1}
	if !reflect.DeepEqual(reportSummary(report), wantReport) {
		t.Fatalf("report = %#v, want %#v", report, wantReport)
	}
	if len(planner.calls) != 0 {
		t.Fatalf("planner calls = %v", planner.calls)
	}
	assertPlannedCaseIDs(t, report.PlannedCases, []string{decidedID})
}

func TestRunStoresButDoesNotPlanSupersededCases(t *testing.T) {
	t.Parallel()

	newID := testCaseID("e")
	decidedID := testCaseID("f")
	newCase := supersededTestAssembly(newID)
	decidedCase := supersededTestAssembly(decidedID)
	store := newFakeStore()
	store.known[decidedID] = true
	store.assemblies[decidedID] = decidedCase
	store.results[decidedID] = casestore.PlanningResult{
		CaseID: decidedID, Attempts: 1, Decision: encodedTestDecision(t, decidedID),
	}
	planner := &fakePlanner{}
	runner := newTestRunner(
		t,
		&fakeCaseSource{assemblies: []casebuilder.Assembly{newCase, decidedCase}},
		store,
		planner,
		time.Date(2026, time.September, 12, 18, 0, 0, 0, time.UTC),
	)

	report, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	wantReport := Report{Observed: 2, Stored: 1, Superseded: 2}
	if !reflect.DeepEqual(reportSummary(report), wantReport) {
		t.Fatalf("report = %#v, want %#v", report, wantReport)
	}
	if len(planner.calls) != 0 || len(report.PlannedCases) != 0 {
		t.Fatalf("planner calls = %v, planned cases = %#v", planner.calls, report.PlannedCases)
	}
}

func TestRunKeepsCurrentObservationForAlreadyDecidedCase(t *testing.T) {
	t.Parallel()

	caseID := testCaseID("d")
	first := testAssembly(caseID)
	first.Request.ObservedAt = time.Date(2026, time.September, 12, 17, 0, 0, 0, time.UTC)
	first.LocalSnapshot.Observation.ObservedAt = first.Request.ObservedAt
	fresh := testAssembly(caseID)
	fresh.Request.ObservedAt = first.Request.ObservedAt.Add(time.Hour)
	fresh.LocalSnapshot.Observation.ObservedAt = fresh.Request.ObservedAt
	store := newFakeStore()
	store.known[caseID] = true
	store.assemblies[caseID] = first
	store.results[caseID] = casestore.PlanningResult{
		CaseID: caseID, Attempts: 1, Decision: encodedTestDecision(t, caseID),
	}
	runner := newTestRunner(
		t,
		&fakeCaseSource{assemblies: []casebuilder.Assembly{fresh}},
		store,
		&fakePlanner{},
		fresh.Request.ObservedAt,
	)

	report, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(report.PlannedCases) != 1 ||
		report.PlannedCases[0].Assembly.Request.ObservedAt != fresh.Request.ObservedAt ||
		report.PlannedCases[0].Assembly.LocalSnapshot.Observation.ObservedAt !=
			fresh.LocalSnapshot.Observation.ObservedAt {
		t.Fatalf("planned cases = %#v", report.PlannedCases)
	}
}

func TestRunRejectsStoredDecisionForAnotherCase(t *testing.T) {
	t.Parallel()

	caseID := testCaseID("b")
	otherID := testCaseID("c")
	store := newFakeStore()
	store.known[caseID] = true
	store.assemblies[caseID] = testAssembly(caseID)
	store.results[caseID] = casestore.PlanningResult{
		CaseID: caseID, Attempts: 1, Decision: encodedTestDecision(t, otherID),
	}
	runner := newTestRunner(
		t,
		&fakeCaseSource{assemblies: []casebuilder.Assembly{testAssembly(caseID)}},
		store,
		&fakePlanner{},
		time.Date(2026, time.September, 12, 18, 0, 0, 0, time.UTC),
	)

	report, err := runner.Run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "does not match observed case") {
		t.Fatalf("error = %v", err)
	}
	if report.Failed != 1 || len(report.PlannedCases) != 0 {
		t.Fatalf("report = %#v", report)
	}
}

func TestRunDoublesRetryDelayAfterEarlierFailures(t *testing.T) {
	t.Parallel()

	caseID := testCaseID("6")
	now := time.Date(2026, time.September, 12, 18, 0, 0, 0, time.UTC)
	expired := now.Add(-time.Minute)
	store := newFakeStore()
	store.known[caseID] = true
	store.results[caseID] = casestore.PlanningResult{
		CaseID: caseID, Attempts: 2, RetryAfter: &expired,
		Failure: &casestore.PlanningFailure{Kind: casestore.PlanningFailureTimeout},
	}
	source := &fakeCaseSource{assemblies: []casebuilder.Assembly{testAssembly(caseID)}}
	planner := &fakePlanner{responses: map[string]plannerResponse{
		caseID: {err: errors.New("still unavailable")},
	}}
	runner := newTestRunner(t, source, store, planner, now)

	report, err := runner.Run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "still unavailable") {
		t.Fatalf("error = %v", err)
	}
	wantReport := Report{Observed: 1, Submitted: 1, Failed: 1}
	if !reflect.DeepEqual(reportSummary(report), wantReport) {
		t.Fatalf("report = %#v, want %#v", report, wantReport)
	}
	if len(store.failures) != 1 ||
		!store.failures[0].retryAfter.Equal(now.Add(4*testInitialBackoff)) {
		t.Fatalf("stored failures = %#v", store.failures)
	}
}

func TestRunContinuesAfterCaseStorageFailure(t *testing.T) {
	t.Parallel()

	brokenID := testCaseID("7")
	workingID := testCaseID("8")
	store := newFakeStore()
	store.putErrors[brokenID] = errors.New("state unavailable")
	source := &fakeCaseSource{assemblies: []casebuilder.Assembly{
		testAssembly(brokenID),
		testAssembly(workingID),
	}}
	planner := &fakePlanner{responses: map[string]plannerResponse{
		workingID: {decision: testDecision(t, workingID)},
	}}
	runner := newTestRunner(
		t, source, store, planner,
		time.Date(2026, time.September, 12, 18, 0, 0, 0, time.UTC),
	)

	report, err := runner.Run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "state unavailable") {
		t.Fatalf("error = %v", err)
	}
	wantReport := Report{Observed: 2, Stored: 1, Submitted: 1, Decided: 1, Failed: 1}
	if !reflect.DeepEqual(reportSummary(report), wantReport) {
		t.Fatalf("report = %#v, want %#v", report, wantReport)
	}
	if !reflect.DeepEqual(planner.calls, []string{workingID}) {
		t.Fatalf("planner calls = %v", planner.calls)
	}
}

func TestBackoffIsBounded(t *testing.T) {
	t.Parallel()

	backoff := Backoff{Initial: testInitialBackoff, Maximum: testMaximumBackoff}
	for attempts, want := range map[uint64]time.Duration{
		0: testInitialBackoff,
		1: 2 * testInitialBackoff,
		2: 4 * testInitialBackoff,
		3: testMaximumBackoff,
		9: testMaximumBackoff,
	} {
		if got := backoff.delay(attempts); got != want {
			t.Fatalf("delay after %d attempts = %s, want %s", attempts, got, want)
		}
	}
}

func TestNewRejectsIncompleteDependencies(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.September, 12, 18, 0, 0, 0, time.UTC)
	valid := Dependencies{
		Cases:           &fakeCaseSource{},
		Store:           newFakeStore(),
		Planner:         &fakePlanner{},
		Clock:           fixedClock{now: now},
		ClassifyFailure: classifyTestFailure,
		Backoff: Backoff{
			Initial: testInitialBackoff,
			Maximum: testMaximumBackoff,
		},
	}
	for name, mutate := range map[string]func(*Dependencies){
		"case source": func(dependencies *Dependencies) { dependencies.Cases = nil },
		"store":       func(dependencies *Dependencies) { dependencies.Store = nil },
		"planner":     func(dependencies *Dependencies) { dependencies.Planner = nil },
		"clock":       func(dependencies *Dependencies) { dependencies.Clock = nil },
		"classifier": func(dependencies *Dependencies) {
			dependencies.ClassifyFailure = nil
		},
		"initial retry": func(dependencies *Dependencies) {
			dependencies.Backoff.Initial = 0
		},
		"maximum retry": func(dependencies *Dependencies) {
			dependencies.Backoff.Maximum = time.Minute
		},
	} {
		mutate := mutate
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			dependencies := valid
			mutate(&dependencies)
			if _, err := New(dependencies); err == nil {
				t.Fatal("invalid dependencies were accepted")
			}
		})
	}
}

type fakeCaseSource struct {
	assemblies []casebuilder.Assembly
	rejections []inspection.Rejection
	err        error
}

func (source *fakeCaseSource) InspectAll(context.Context) (inspection.Result, error) {
	return inspection.Result{
		Assemblies: source.assemblies,
		Rejections: source.rejections,
	}, source.err
}

type storedFailure struct {
	caseID      string
	failure     casestore.PlanningFailure
	attemptedAt time.Time
	retryAfter  time.Time
}

type fakeStore struct {
	known       map[string]bool
	assemblies  map[string]casebuilder.Assembly
	results     map[string]casestore.PlanningResult
	putErrors   map[string]error
	failures    []storedFailure
	decisions   []string
	decisionErr error
	failureErr  error
}

func newFakeStore() *fakeStore {
	return &fakeStore{
		known:      make(map[string]bool),
		assemblies: make(map[string]casebuilder.Assembly),
		results:    make(map[string]casestore.PlanningResult),
		putErrors:  make(map[string]error),
	}
}

func (store *fakeStore) PutAssembly(assembly casebuilder.Assembly) (bool, error) {
	caseID := assembly.Request.CaseID
	if err := store.putErrors[caseID]; err != nil {
		return false, err
	}
	if store.known[caseID] {
		return false, nil
	}
	store.known[caseID] = true
	store.assemblies[caseID] = assembly
	return true, nil
}

func (store *fakeStore) GetPlannedCase(caseID string) (casestore.PlannedCase, error) {
	assembly, found := store.assemblies[caseID]
	if !found {
		return casestore.PlannedCase{}, errors.New("stored assembly not found")
	}
	result, found := store.results[caseID]
	if !found || !result.HasDecision() {
		return casestore.PlannedCase{}, errors.New("stored decision not found")
	}
	decision, err := contracts.DecodeDecision(result.Decision)
	if err != nil {
		return casestore.PlannedCase{}, err
	}
	return casestore.PlannedCase{Assembly: assembly, Decision: decision}, nil
}

func (store *fakeStore) GetPlanningResult(
	caseID string,
) (casestore.PlanningResult, bool, error) {
	result, found := store.results[caseID]
	return result, found, nil
}

func (store *fakeStore) PutPlanningFailure(
	caseID string,
	failure casestore.PlanningFailure,
	attemptedAt time.Time,
	retryAfter time.Time,
) (casestore.PlanningResult, bool, error) {
	if store.failureErr != nil {
		return casestore.PlanningResult{}, false, store.failureErr
	}
	store.failures = append(store.failures, storedFailure{
		caseID: caseID, failure: failure, attemptedAt: attemptedAt, retryAfter: retryAfter,
	})
	previous := store.results[caseID]
	result := casestore.PlanningResult{
		CaseID: caseID, Attempts: previous.Attempts + 1, RetryAfter: &retryAfter, Failure: &failure,
	}
	store.results[caseID] = result
	return result, true, nil
}

func (store *fakeStore) PutPlanningDecision(
	caseID string,
	decision contracts.RepairDecisionV3,
	attemptedAt time.Time,
) (casestore.PlanningResult, bool, error) {
	if store.decisionErr != nil {
		return casestore.PlanningResult{}, false, store.decisionErr
	}
	encoded, err := contracts.EncodeDecision(decision)
	if err != nil {
		return casestore.PlanningResult{}, false, err
	}
	store.decisions = append(store.decisions, caseID)
	previous := store.results[caseID]
	result := casestore.PlanningResult{
		CaseID: caseID, Attempts: previous.Attempts + 1, AttemptedAt: attemptedAt, Decision: encoded,
	}
	store.results[caseID] = result
	return result, true, nil
}

type plannerResponse struct {
	decision contracts.RepairDecisionV3
	err      error
}

type fakePlanner struct {
	responses map[string]plannerResponse
	calls     []string
}

func (planner *fakePlanner) Plan(
	_ context.Context,
	repairCase contracts.RepairCaseV3,
) (contracts.RepairDecisionV3, error) {
	planner.calls = append(planner.calls, repairCase.CaseID)
	response, found := planner.responses[repairCase.CaseID]
	if !found {
		return contracts.RepairDecisionV3{}, errors.New("unexpected planner call")
	}
	return response.decision, response.err
}

type fixedClock struct {
	now time.Time
}

func (clock fixedClock) Now() time.Time {
	return clock.now
}

func newTestRunner(
	t *testing.T,
	source CaseSource,
	store ResultStore,
	planner controller.Planner,
	now time.Time,
) *Runner {
	t.Helper()
	runner, err := New(Dependencies{
		Cases:           source,
		Store:           store,
		Planner:         planner,
		Clock:           fixedClock{now: now},
		ClassifyFailure: classifyTestFailure,
		Backoff: Backoff{
			Initial: testInitialBackoff,
			Maximum: testMaximumBackoff,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return runner
}

func classifyTestFailure(error) casestore.PlanningFailure {
	return casestore.PlanningFailure{Kind: casestore.PlanningFailureUnavailable}
}

func testAssembly(caseID string) casebuilder.Assembly {
	return casebuilder.Assembly{Request: contracts.RepairCaseV3{CaseID: caseID}}
}

func supersededTestAssembly(caseID string) casebuilder.Assembly {
	assembly := testAssembly(caseID)
	assembly.LocalSnapshot.Observation.Movie = &controller.RadarrMovie{HasFile: true}
	assembly.LocalSnapshot.Observation.ManualImports = []controller.RadarrManualImport{{
		Rejections: []controller.RadarrManualImportRejection{{
			Code: controller.RejectionNotQualityUpgrade,
		}},
	}}
	return assembly
}

func reportSummary(report Report) Report {
	report.metrics = metricData{}
	report.PlannedCases = nil
	report.Rejections = nil
	report.Queue = nil
	report.Reviews = nil
	return report
}

func assertPlannedCaseIDs(
	t *testing.T,
	planned []casestore.PlannedCase,
	wanted []string,
) {
	t.Helper()
	actual := make([]string, len(planned))
	for index, current := range planned {
		actual[index] = current.Assembly.Request.CaseID
		if current.Decision.CaseID() != actual[index] {
			t.Fatalf("planned case %q has decision for %q", actual[index], current.Decision.CaseID())
		}
	}
	if !reflect.DeepEqual(actual, wanted) {
		t.Fatalf("planned case IDs = %v, want %v", actual, wanted)
	}
}

func testDecision(t *testing.T, caseID string) contracts.RepairDecisionV3 {
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

func encodedTestDecision(t *testing.T, caseID string) []byte {
	t.Helper()
	encoded, err := contracts.EncodeDecision(testDecision(t, caseID))
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func testCaseID(character string) string {
	return "sha256:" + strings.Repeat(character, 64)
}

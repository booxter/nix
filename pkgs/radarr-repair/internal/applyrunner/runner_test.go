package applyrunner

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/applyselection"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/repairexecution"
)

func TestRunExecutesFirstPermittedUnfinishedRepair(t *testing.T) {
	t.Parallel()

	store := &runnerStore{
		joins: map[string]casestore.JoinExecution{
			"finished": {State: casestore.JoinFailed},
			"resume":   {State: casestore.JoinPublished},
		},
	}
	executor := &runnerExecutor{}
	locker := newRunnerLocker()
	executor.during = func() {
		if locker.acquired != 1 || locker.lease.released {
			t.Fatalf(
				"repair ran outside lease: acquisitions = %d, released = %t",
				locker.acquired,
				locker.lease.released,
			)
		}
	}
	runner := newTestRunner(t, store, executor, locker)
	report, err := runner.Run(context.Background(), []casestore.PlannedCase{
		runnerPlan("no-repair", contracts.ActionNoRepair),
		runnerPlan("disallowed", contracts.ActionManualImportFile),
		runnerPlan("finished", contracts.ActionJoinParts),
		runnerPlan("new", contracts.ActionJoinParts),
		runnerPlan("resume", contracts.ActionJoinParts),
	}, applyselection.Policy{
		AllowedActions: map[contracts.DecisionAction]bool{
			contracts.ActionJoinParts: true,
		},
		Limit: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if report.Permitted != 3 || report.Finished != 1 || report.Selected != 1 {
		t.Fatalf("report = %#v", report)
	}
	if got, want := executor.calls, []string{"new"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("executed cases = %v, want %v", got, want)
	}
	if len(report.Executions) != 1 || report.Executions[0].CaseID != "new" ||
		report.Executions[0].Action != contracts.ActionJoinParts {
		t.Fatalf("executions = %#v", report.Executions)
	}
	assertLease(t, locker, true)
}

func TestRunResumesUnfinishedRepair(t *testing.T) {
	t.Parallel()

	store := &runnerStore{manualImports: map[string]casestore.ManualImportExecution{
		"resume": {State: casestore.ManualImportRequested},
	}}
	executor := &runnerExecutor{}
	locker := newRunnerLocker()
	runner := newTestRunner(t, store, executor, locker)
	report, err := runner.Run(
		context.Background(),
		[]casestore.PlannedCase{runnerPlan("resume", contracts.ActionManualImportFile)},
		applyselection.Policy{
			AllowedActions: map[contracts.DecisionAction]bool{
				contracts.ActionManualImportFile: true,
			},
			Limit: 1,
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Executions) != 1 || !reflect.DeepEqual(executor.calls, []string{"resume"}) {
		t.Fatalf("report = %#v, executed cases = %v", report, executor.calls)
	}
	assertLease(t, locker, true)
}

func TestRunDoesNotLockWithoutSelectedRepair(t *testing.T) {
	t.Parallel()

	locker := newRunnerLocker()
	runner := newTestRunner(t, &runnerStore{}, &runnerExecutor{}, locker)
	report, err := runner.Run(
		context.Background(),
		[]casestore.PlannedCase{runnerPlan("join", contracts.ActionJoinParts)},
		applyselection.Policy{Limit: 1},
	)
	if err != nil {
		t.Fatal(err)
	}
	if report.Selected != 0 || locker.acquired != 0 {
		t.Fatalf("report = %#v, lock acquisitions = %d", report, locker.acquired)
	}
}

func TestRunStopsAfterExecutionFailureAndReleasesLease(t *testing.T) {
	t.Parallel()

	wantErr := errors.New("execution failed")
	executor := &runnerExecutor{errors: map[string]error{"first": wantErr}}
	locker := newRunnerLocker()
	runner := newTestRunner(t, &runnerStore{}, executor, locker)
	report, err := runner.Run(context.Background(), []casestore.PlannedCase{
		runnerPlan("first", contracts.ActionJoinParts),
		runnerPlan("second", contracts.ActionJoinParts),
	}, applyselection.Policy{
		AllowedActions: map[contracts.DecisionAction]bool{
			contracts.ActionJoinParts: true,
		},
		Limit: 2,
	})
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want %v", err, wantErr)
	}
	if got, want := executor.calls, []string{"first"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("executed cases = %v, want %v", got, want)
	}
	if report.Selected != 2 || len(report.Executions) != 1 {
		t.Fatalf("report = %#v", report)
	}
	assertLease(t, locker, true)
}

func TestRunFailsBeforeExecutionWhenProgressCannotBeRead(t *testing.T) {
	t.Parallel()

	wantErr := errors.New("unreadable execution")
	store := &runnerStore{errors: map[string]error{"broken": wantErr}}
	executor := &runnerExecutor{}
	locker := newRunnerLocker()
	runner := newTestRunner(t, store, executor, locker)
	_, err := runner.Run(
		context.Background(),
		[]casestore.PlannedCase{runnerPlan("broken", contracts.ActionJoinParts)},
		applyselection.Policy{
			AllowedActions: map[contracts.DecisionAction]bool{
				contracts.ActionJoinParts: true,
			},
			Limit: 1,
		},
	)
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want %v", err, wantErr)
	}
	if len(executor.calls) != 0 || locker.acquired != 0 {
		t.Fatalf("executed cases = %v, lock acquisitions = %d", executor.calls, locker.acquired)
	}
}

func TestRunFailsBeforeExecutionWhenLeaseCannotBeAcquired(t *testing.T) {
	t.Parallel()

	wantErr := errors.New("busy")
	executor := &runnerExecutor{}
	locker := &runnerLocker{err: wantErr}
	runner := newTestRunner(t, &runnerStore{}, executor, locker)
	_, err := runner.Run(
		context.Background(),
		[]casestore.PlannedCase{runnerPlan("join", contracts.ActionJoinParts)},
		applyselection.Policy{
			AllowedActions: map[contracts.DecisionAction]bool{
				contracts.ActionJoinParts: true,
			},
			Limit: 1,
		},
	)
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want %v", err, wantErr)
	}
	if len(executor.calls) != 0 {
		t.Fatalf("executed cases = %v", executor.calls)
	}
}

func TestNewRejectsMissingDependencies(t *testing.T) {
	t.Parallel()

	valid := Dependencies{
		Store: &runnerStore{}, Executor: &runnerExecutor{}, Locker: newRunnerLocker(),
	}
	tests := []struct {
		name   string
		change func(*Dependencies)
		want   string
	}{
		{"store", func(dependencies *Dependencies) { dependencies.Store = nil }, "store"},
		{"executor", func(dependencies *Dependencies) { dependencies.Executor = nil }, "executor"},
		{"locker", func(dependencies *Dependencies) { dependencies.Locker = nil }, "locker"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dependencies := valid
			test.change(&dependencies)
			if _, err := New(dependencies); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want containing %q", err, test.want)
			}
		})
	}
}

func newTestRunner(
	t *testing.T,
	store repairexecution.ExecutionStore,
	executor Executor,
	locker Locker,
) *Runner {
	t.Helper()
	runner, err := New(Dependencies{Store: store, Executor: executor, Locker: locker})
	if err != nil {
		t.Fatal(err)
	}
	return runner
}

type runnerStore struct {
	manualImports map[string]casestore.ManualImportExecution
	joins         map[string]casestore.JoinExecution
	errors        map[string]error
}

func (store *runnerStore) GetManualImportExecution(
	caseID string,
) (casestore.ManualImportExecution, bool, error) {
	if err := store.errors[caseID]; err != nil {
		return casestore.ManualImportExecution{}, false, err
	}
	execution, found := store.manualImports[caseID]
	return execution, found, nil
}

func (store *runnerStore) GetJoinExecution(
	caseID string,
) (casestore.JoinExecution, bool, error) {
	if err := store.errors[caseID]; err != nil {
		return casestore.JoinExecution{}, false, err
	}
	execution, found := store.joins[caseID]
	return execution, found, nil
}

type runnerExecutor struct {
	calls  []string
	errors map[string]error
	during func()
}

func (executor *runnerExecutor) Execute(
	_ context.Context,
	assembly casebuilder.Assembly,
	_ contracts.RepairDecisionV1,
) (repairexecution.Result, error) {
	caseID := assembly.Request.CaseID
	executor.calls = append(executor.calls, caseID)
	if executor.during != nil {
		executor.during()
	}
	return repairexecution.Result{}, executor.errors[caseID]
}

type runnerLease struct {
	released bool
}

func (lease *runnerLease) Release() {
	lease.released = true
}

type runnerLocker struct {
	acquired int
	lease    *runnerLease
	err      error
}

func newRunnerLocker() *runnerLocker {
	return &runnerLocker{lease: &runnerLease{}}
}

func (locker *runnerLocker) Acquire() (Lease, error) {
	locker.acquired++
	if locker.err != nil {
		return nil, locker.err
	}
	return locker.lease, nil
}

func assertLease(t *testing.T, locker *runnerLocker, released bool) {
	t.Helper()
	if locker.acquired != 1 || locker.lease.released != released {
		t.Fatalf(
			"lock acquisitions = %d, released = %t",
			locker.acquired,
			locker.lease.released,
		)
	}
}

func runnerPlan(caseID string, action contracts.DecisionAction) casestore.PlannedCase {
	planned := casestore.PlannedCase{
		Assembly: casebuilder.Assembly{
			Request: contracts.RepairCaseV1{CaseID: caseID},
		},
		Decision: contracts.RepairDecisionV1{Kind: action},
	}
	switch action {
	case contracts.ActionNoRepair:
		planned.Decision.NoRepair = &contracts.NoRepairDecision{CaseID: caseID}
	case contracts.ActionManualImportFile:
		planned.Decision.ManualImportFile = &contracts.ManualImportFileDecision{CaseID: caseID}
	case contracts.ActionJoinParts:
		planned.Decision.JoinParts = &contracts.JoinDecision{CaseID: caseID}
	}
	return planned
}

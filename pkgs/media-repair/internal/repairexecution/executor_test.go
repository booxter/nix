package repairexecution

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/executioncheck"
)

func TestExecutorReturnsPreconditionRejectionWithoutMutation(t *testing.T) {
	t.Parallel()

	checker := &fakeChecker{result: executioncheck.Result{
		Rejections: []executioncheck.Rejection{{Reason: executioncheck.CaseChanged}},
	}}
	manual := &fakeManualImporter{}
	joins := &fakeJoinExecutor{}
	imports := &fakeJoinedFileImporter{}
	executor := testExecutor(t, checker, manual, joins, imports)

	result, err := executor.Execute(context.Background(), caseAssembly(), contracts.RepairDecisionV3{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Check.Accepted() || len(result.Check.Rejections) != 1 ||
		manual.calls != 0 || joins.calls != 0 || imports.calls != 0 {
		t.Fatalf("result = %#v, calls = %d/%d/%d", result, manual.calls, joins.calls, imports.calls)
	}
}

func TestExecutorRunsAuthorizedManualImport(t *testing.T) {
	t.Parallel()

	authorized := manualAuthorization()
	checker := &fakeChecker{result: acceptedManual(authorized)}
	manual := &fakeManualImporter{execution: casestore.ManualImportExecution{
		State: casestore.ManualImportImported,
	}}
	joins := &fakeJoinExecutor{}
	imports := &fakeJoinedFileImporter{}
	executor := testExecutor(t, checker, manual, joins, imports)

	result, err := executor.Execute(context.Background(), caseAssembly(), contracts.RepairDecisionV3{})
	if err != nil {
		t.Fatal(err)
	}
	if result.ManualImport == nil ||
		result.ManualImport.State != casestore.ManualImportImported ||
		!reflect.DeepEqual(manual.authorized, authorized) ||
		joins.calls != 0 || imports.calls != 0 {
		t.Fatalf("result = %#v, manual authorization = %#v", result, manual.authorized)
	}
}

func TestExecutorRunsPublishedJoinImport(t *testing.T) {
	t.Parallel()

	authorized := joinAuthorization()
	checker := &fakeChecker{result: acceptedJoin(authorized)}
	manual := &fakeManualImporter{}
	joins := &fakeJoinExecutor{execution: casestore.JoinExecution{
		State: casestore.JoinPublished,
	}}
	imports := &fakeJoinedFileImporter{execution: casestore.JoinExecution{
		State: casestore.JoinImported,
	}}
	executor := testExecutor(t, checker, manual, joins, imports)

	result, err := executor.Execute(context.Background(), caseAssembly(), contracts.RepairDecisionV3{})
	if err != nil {
		t.Fatal(err)
	}
	wantPaths := map[controller.FileID]string{
		"file:first":  "/downloads/Movie/first.mkv",
		"file:second": "/downloads/Movie/second.mkv",
	}
	if result.Join == nil || result.Join.State != casestore.JoinImported ||
		!reflect.DeepEqual(joins.paths, wantPaths) ||
		imports.caseID != authorized.CaseID || manual.calls != 0 {
		t.Fatalf(
			"result = %#v, paths = %#v, import case = %q",
			result,
			joins.paths,
			imports.caseID,
		)
	}
}

func TestExecutorDoesNotImportUnpublishedJoin(t *testing.T) {
	t.Parallel()

	for _, state := range []casestore.JoinExecutionState{
		casestore.JoinDiscarded,
		casestore.JoinFailed,
	} {
		t.Run(string(state), func(t *testing.T) {
			t.Parallel()
			authorized := joinAuthorization()
			joins := &fakeJoinExecutor{execution: casestore.JoinExecution{State: state}}
			imports := &fakeJoinedFileImporter{}
			executor := testExecutor(
				t,
				&fakeChecker{result: acceptedJoin(authorized)},
				&fakeManualImporter{},
				joins,
				imports,
			)

			result, err := executor.Execute(
				context.Background(),
				caseAssembly(),
				contracts.RepairDecisionV3{},
			)
			if err != nil || result.Join == nil || result.Join.State != state ||
				imports.calls != 0 {
				t.Fatalf("result = %#v, error = %v, import calls = %d", result, err, imports.calls)
			}
		})
	}
}

func TestExecutorImportsPublishedBluRayRemux(t *testing.T) {
	t.Parallel()
	authorized := decisionpolicy.AuthorizedRemux{
		CaseID:   "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Playlist: decisionpolicy.AuthorizedRemuxFile{FileID: "file:first"},
		Clips:    []decisionpolicy.AuthorizedRemuxFile{{FileID: "file:second"}},
	}
	remuxes := &fakeRemuxExecutor{execution: casestore.RemuxExecution{State: casestore.RemuxPublished}}
	imports := &fakeRemuxFileImporter{execution: casestore.RemuxExecution{State: casestore.RemuxImported}}
	executor, err := New(Dependencies{
		Store: &fakeExecutionStore{},
		Checker: &fakeChecker{result: executioncheck.Result{
			Authorization: executioncheck.Authorization{Remux: &authorized},
		}},
		ManualImports: &fakeManualImporter{}, Joins: &fakeJoinExecutor{},
		JoinedFileImports: &fakeJoinedFileImporter{},
		Remuxes:           remuxes, RemuxFileImports: imports,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := executor.Execute(context.Background(), caseAssembly(), contracts.RepairDecisionV3{})
	if err != nil || result.Remux == nil || result.Remux.State != casestore.RemuxImported ||
		remuxes.calls != 1 || imports.calls != 1 || imports.caseID != authorized.CaseID ||
		!reflect.DeepEqual(remuxes.paths, map[controller.FileID]string{
			"file:first":  "/downloads/Movie/first.mkv",
			"file:second": "/downloads/Movie/second.mkv",
		}) {
		t.Fatalf("result = %#v, remux paths = %#v, import calls = %d, error = %v",
			result, remuxes.paths, imports.calls, err)
	}
}

func TestExecutorStopsAfterDependencyFailure(t *testing.T) {
	t.Parallel()

	t.Run("check", func(t *testing.T) {
		t.Parallel()
		failure := errors.New("inspection unavailable")
		executor := testExecutor(
			t,
			&fakeChecker{err: failure},
			&fakeManualImporter{},
			&fakeJoinExecutor{},
			&fakeJoinedFileImporter{},
		)
		if _, err := executor.Execute(
			context.Background(), caseAssembly(), contracts.RepairDecisionV3{},
		); !errors.Is(err, failure) {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("join", func(t *testing.T) {
		t.Parallel()
		failure := errors.New("worker unavailable")
		joins := &fakeJoinExecutor{err: failure}
		imports := &fakeJoinedFileImporter{}
		executor := testExecutor(
			t,
			&fakeChecker{result: acceptedJoin(joinAuthorization())},
			&fakeManualImporter{},
			joins,
			imports,
		)
		result, err := executor.Execute(
			context.Background(), caseAssembly(), contracts.RepairDecisionV3{},
		)
		if !errors.Is(err, failure) || result.Join == nil || imports.calls != 0 {
			t.Fatalf("result = %#v, error = %v, import calls = %d", result, err, imports.calls)
		}
	})

	t.Run("missing path", func(t *testing.T) {
		t.Parallel()
		authorized := joinAuthorization()
		authorized.OrderedParts[1].FileID = "file:missing"
		joins := &fakeJoinExecutor{}
		executor := testExecutor(
			t,
			&fakeChecker{result: acceptedJoin(authorized)},
			&fakeManualImporter{},
			joins,
			&fakeJoinedFileImporter{},
		)
		if _, err := executor.Execute(
			context.Background(), caseAssembly(), contracts.RepairDecisionV3{},
		); err == nil || joins.calls != 0 {
			t.Fatalf("error = %v, join calls = %d", err, joins.calls)
		}
	})
}

func TestNewRequiresDependencies(t *testing.T) {
	t.Parallel()

	valid := Dependencies{
		Store: &fakeExecutionStore{}, Checker: &fakeChecker{}, ManualImports: &fakeManualImporter{},
		Joins: &fakeJoinExecutor{}, JoinedFileImports: &fakeJoinedFileImporter{},
		Remuxes: &fakeRemuxExecutor{}, RemuxFileImports: &fakeRemuxFileImporter{},
	}
	tests := []Dependencies{
		{Checker: valid.Checker, ManualImports: valid.ManualImports, Joins: valid.Joins, JoinedFileImports: valid.JoinedFileImports},
		{Store: valid.Store, ManualImports: valid.ManualImports, Joins: valid.Joins, JoinedFileImports: valid.JoinedFileImports},
		{Store: valid.Store, Checker: valid.Checker, Joins: valid.Joins, JoinedFileImports: valid.JoinedFileImports},
		{Store: valid.Store, Checker: valid.Checker, ManualImports: valid.ManualImports, JoinedFileImports: valid.JoinedFileImports},
		{Store: valid.Store, Checker: valid.Checker, ManualImports: valid.ManualImports, Joins: valid.Joins},
	}
	for _, dependencies := range tests {
		if _, err := New(dependencies); err == nil {
			t.Fatal("incomplete dependencies were accepted")
		}
	}
}

type fakeChecker struct {
	result executioncheck.Result
	err    error
	calls  int
}

func (checker *fakeChecker) Check(
	context.Context,
	casebuilder.Assembly,
	contracts.RepairDecisionV3,
) (executioncheck.Result, error) {
	checker.calls++
	return checker.result, checker.err
}

type fakeExecutionStore struct {
	manual      casestore.ManualImportExecution
	manualFound bool
	join        casestore.JoinExecution
	joinFound   bool
	err         error
}

func (store *fakeExecutionStore) GetManualImportExecution(
	string,
) (casestore.ManualImportExecution, bool, error) {
	return store.manual, store.manualFound, store.err
}

func (store *fakeExecutionStore) GetJoinExecution(
	string,
) (casestore.JoinExecution, bool, error) {
	return store.join, store.joinFound, store.err
}

func (store *fakeExecutionStore) GetRemuxExecution(
	string,
) (casestore.RemuxExecution, bool, error) {
	return casestore.RemuxExecution{}, false, store.err
}

type fakeManualImporter struct {
	execution  casestore.ManualImportExecution
	authorized decisionpolicy.AuthorizedManualImport
	err        error
	calls      int
}

func (importer *fakeManualImporter) Execute(
	_ context.Context,
	authorized decisionpolicy.AuthorizedManualImport,
) (casestore.ManualImportExecution, error) {
	importer.calls++
	importer.authorized = authorized
	return importer.execution, importer.err
}

type fakeJoinExecutor struct {
	execution  casestore.JoinExecution
	authorized decisionpolicy.AuthorizedJoin
	paths      map[controller.FileID]string
	err        error
	calls      int
}

func (executor *fakeJoinExecutor) Execute(
	_ context.Context,
	authorized decisionpolicy.AuthorizedJoin,
	paths map[controller.FileID]string,
) (casestore.JoinExecution, error) {
	executor.calls++
	executor.authorized = authorized
	executor.paths = paths
	return executor.execution, executor.err
}

type fakeJoinedFileImporter struct {
	execution casestore.JoinExecution
	caseID    string
	err       error
	calls     int
}

type fakeRemuxExecutor struct {
	execution casestore.RemuxExecution
	paths     map[controller.FileID]string
	calls     int
}

func (executor *fakeRemuxExecutor) Execute(
	_ context.Context,
	_ decisionpolicy.AuthorizedRemux,
	paths map[controller.FileID]string,
) (casestore.RemuxExecution, error) {
	executor.calls++
	executor.paths = paths
	return executor.execution, nil
}

type fakeRemuxFileImporter struct {
	execution casestore.RemuxExecution
	caseID    string
	calls     int
}

func (importer *fakeRemuxFileImporter) Execute(
	_ context.Context,
	caseID string,
) (casestore.RemuxExecution, error) {
	importer.calls++
	importer.caseID = caseID
	return importer.execution, nil
}

func (importer *fakeJoinedFileImporter) Execute(
	_ context.Context,
	caseID string,
) (casestore.JoinExecution, error) {
	importer.calls++
	importer.caseID = caseID
	return importer.execution, importer.err
}

func testExecutor(
	t *testing.T,
	checker Checker,
	manual ManualImporter,
	joins JoinExecutor,
	imports JoinedFileImporter,
) *Executor {
	t.Helper()
	return testExecutorWithStore(
		t,
		&fakeExecutionStore{},
		checker,
		manual,
		joins,
		imports,
	)
}

func testExecutorWithStore(
	t *testing.T,
	store ExecutionStore,
	checker Checker,
	manual ManualImporter,
	joins JoinExecutor,
	imports JoinedFileImporter,
) *Executor {
	t.Helper()
	executor, err := New(Dependencies{
		Store: store, Checker: checker, ManualImports: manual, Joins: joins,
		JoinedFileImports: imports,
		Remuxes:           &fakeRemuxExecutor{}, RemuxFileImports: &fakeRemuxFileImporter{},
	})
	if err != nil {
		t.Fatal(err)
	}
	return executor
}

func acceptedManual(
	authorized decisionpolicy.AuthorizedManualImport,
) executioncheck.Result {
	return executioncheck.Result{
		Authorization: executioncheck.Authorization{ManualImport: &authorized},
		Rejections:    []executioncheck.Rejection{},
	}
}

func acceptedJoin(authorized decisionpolicy.AuthorizedJoin) executioncheck.Result {
	return executioncheck.Result{
		Authorization: executioncheck.Authorization{Join: &authorized},
		Rejections:    []executioncheck.Rejection{},
	}
}

func manualAuthorization() decisionpolicy.AuthorizedManualImport {
	return decisionpolicy.AuthorizedManualImport{
		CaseID:       "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		CapabilityID: "capability:manual",
		FileID:       "file:first",
	}
}

func joinAuthorization() decisionpolicy.AuthorizedJoin {
	return decisionpolicy.AuthorizedJoin{
		CaseID:       "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		CapabilityID: "capability:join",
		OrderedParts: []decisionpolicy.AuthorizedJoinPart{
			{FileID: "file:first"},
			{FileID: "file:second"},
		},
	}
}

func caseAssembly() casebuilder.Assembly {
	return casebuilder.Assembly{
		LocalSnapshot: casebuilder.LocalSnapshot{
			Observation: casebuilder.Observation{
				Inventory: controller.FileInventory{
					Paths: []controller.FilePathMapping{
						{FileID: "file:first", AbsolutePath: "/downloads/Movie/first.mkv"},
						{FileID: "file:second", AbsolutePath: "/downloads/Movie/second.mkv"},
						{FileID: "file:extra", AbsolutePath: "/downloads/Movie/extra.mkv"},
					},
				},
			},
		},
	}
}

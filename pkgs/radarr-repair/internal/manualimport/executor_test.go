package manualimport

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/radarr"
)

func TestExecutorConfirmsExactImportedFile(t *testing.T) {
	t.Parallel()

	authorized := testAuthorization()
	now := time.Date(2026, time.September, 13, 16, 0, 0, 0, time.UTC)
	exact := importedFile(authorized, now.Add(2*time.Second))
	otherPath := exact
	otherPath.HistoryID++
	otherPath.DroppedPath = "/downloads/Other/movie.mkv"
	old := exact
	old.HistoryID--
	old.OccurredAt = now.Add(-time.Second)
	store := &fakeStore{}
	radarrClient := &fakeRadarr{
		requestCommand: radarr.Command{
			ID: 81, Name: "ManualImport", Status: radarr.CommandQueued,
			Result: radarr.CommandResultUnknown,
		},
		commands: []radarr.Command{{
			ID: 81, Name: "ManualImport", Status: radarr.CommandCompleted,
			Result: radarr.CommandResultSuccessful,
		}},
		imports: [][]controller.RadarrImportedFile{{old, otherPath}, {exact}},
	}
	waiter := &fakeWaiter{}
	executor := newTestExecutor(t, radarrClient, store, waiter, now)

	execution, err := executor.Execute(context.Background(), authorized)
	if err != nil {
		t.Fatal(err)
	}
	if execution.State != casestore.ManualImportImported || execution.Confirmation == nil ||
		execution.Confirmation.HistoryID != exact.HistoryID ||
		execution.Confirmation.ImportedPath != exact.ImportedPath {
		t.Fatalf("execution = %#v", execution)
	}
	if radarrClient.requestCalls != 1 || radarrClient.commandReads != 1 ||
		radarrClient.historyReads != 2 || waiter.waits != 1 {
		t.Fatalf(
			"request calls = %d, command reads = %d, history reads = %d, waits = %d",
			radarrClient.requestCalls,
			radarrClient.commandReads,
			radarrClient.historyReads,
			waiter.waits,
		)
	}
	if !reflect.DeepEqual(radarrClient.requested, authorized) {
		t.Fatalf("requested authorization = %#v", radarrClient.requested)
	}
}

func TestExecutorResumesRequestedImportWithoutSubmittingAgain(t *testing.T) {
	t.Parallel()

	authorized := testAuthorization()
	now := time.Date(2026, time.September, 13, 16, 0, 0, 0, time.UTC)
	commandID := int64(81)
	store := &fakeStore{
		found: true,
		execution: casestore.ManualImportExecution{
			Version: casestore.ManualImportExecutionVersionV1,
			CaseID:  authorized.CaseID, CapabilityID: authorized.CapabilityID,
			FileID: authorized.FileID, ExpectedFingerprint: authorized.ExpectedFingerprint,
			State: casestore.ManualImportRequested, PreparedAt: now.Add(-time.Minute),
			UpdatedAt: now.Add(-time.Minute), CommandID: &commandID,
		},
	}
	radarrClient := &fakeRadarr{
		imports: [][]controller.RadarrImportedFile{{importedFile(authorized, now)}},
	}
	executor := newTestExecutor(t, radarrClient, store, &fakeWaiter{}, now)

	execution, err := executor.Execute(context.Background(), authorized)
	if err != nil || execution.State != casestore.ManualImportImported {
		t.Fatalf("execution = %#v, error = %v", execution, err)
	}
	if radarrClient.requestCalls != 0 || radarrClient.commandReads != 0 {
		t.Fatalf(
			"request calls = %d, command reads = %d",
			radarrClient.requestCalls,
			radarrClient.commandReads,
		)
	}
}

func TestExecutorNeverRepeatsUncertainSubmission(t *testing.T) {
	t.Parallel()

	authorized := testAuthorization()
	now := time.Date(2026, time.September, 13, 16, 0, 0, 0, time.UTC)
	store := &fakeStore{}
	radarrClient := &fakeRadarr{requestErr: errors.New("response was lost")}
	executor := newTestExecutor(t, radarrClient, store, &fakeWaiter{}, now)

	execution, err := executor.Execute(context.Background(), authorized)
	assertUncertainSubmission(t, execution, err)
	if radarrClient.requestCalls != 1 || radarrClient.historyReads != 1 {
		t.Fatalf(
			"request calls = %d, history reads = %d",
			radarrClient.requestCalls,
			radarrClient.historyReads,
		)
	}

	radarrClient.requestErr = nil
	execution, err = executor.Execute(context.Background(), authorized)
	assertUncertainSubmission(t, execution, err)
	if radarrClient.requestCalls != 1 || radarrClient.historyReads != 2 {
		t.Fatalf(
			"request calls after restart = %d, history reads = %d",
			radarrClient.requestCalls,
			radarrClient.historyReads,
		)
	}

	radarrClient.imports = [][]controller.RadarrImportedFile{{
		importedFile(authorized, now.Add(time.Second)),
	}}
	execution, err = executor.Execute(context.Background(), authorized)
	if err != nil || execution.State != casestore.ManualImportImported {
		t.Fatalf("recovered execution = %#v, error = %v", execution, err)
	}
	if radarrClient.requestCalls != 1 {
		t.Fatalf("request calls after confirmation = %d", radarrClient.requestCalls)
	}
}

func TestExecutorRecordsDefiniteCommandFailure(t *testing.T) {
	t.Parallel()

	authorized := testAuthorization()
	now := time.Date(2026, time.September, 13, 16, 0, 0, 0, time.UTC)
	store := &fakeStore{}
	radarrClient := &fakeRadarr{
		requestCommand: radarr.Command{
			ID: 81, Name: "ManualImport", Status: radarr.CommandQueued,
			Result: radarr.CommandResultUnknown,
		},
		commands: []radarr.Command{{
			ID: 81, Name: "ManualImport", Status: radarr.CommandFailed,
			Result: radarr.CommandResultUnsuccessful,
		}},
	}
	executor := newTestExecutor(t, radarrClient, store, &fakeWaiter{}, now)

	execution, err := executor.Execute(context.Background(), authorized)
	if err != nil || execution.State != casestore.ManualImportFailed {
		t.Fatalf("execution = %#v, error = %v", execution, err)
	}
	if store.failedCalls != 1 {
		t.Fatalf("failed transitions = %d", store.failedCalls)
	}
}

func TestExecutorLeavesUnconfirmedCommandForLaterRecovery(t *testing.T) {
	t.Parallel()

	authorized := testAuthorization()
	now := time.Date(2026, time.September, 13, 16, 0, 0, 0, time.UTC)
	mismatch := importedFile(authorized, now.Add(time.Second))
	mismatch.DownloadID = "different-download"
	store := &fakeStore{}
	radarrClient := &fakeRadarr{
		requestCommand: radarr.Command{
			ID: 81, Name: "ManualImport", Status: radarr.CommandQueued,
			Result: radarr.CommandResultUnknown,
		},
		commands: []radarr.Command{{
			ID: 81, Name: "ManualImport", Status: radarr.CommandCompleted,
			Result: radarr.CommandResultSuccessful,
		}},
		imports: [][]controller.RadarrImportedFile{{mismatch}},
	}
	waiter := &fakeWaiter{err: context.DeadlineExceeded}
	executor := newTestExecutor(t, radarrClient, store, waiter, now)

	execution, err := executor.Execute(context.Background(), authorized)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error = %v", err)
	}
	if execution.State != casestore.ManualImportRequested || store.importedCalls != 0 {
		t.Fatalf("execution = %#v, imported transitions = %d", execution, store.importedCalls)
	}
	if waiter.waits != 1 {
		t.Fatalf("waits = %d", waiter.waits)
	}
}

func assertUncertainSubmission(
	t *testing.T,
	execution casestore.ManualImportExecution,
	err error,
) {
	t.Helper()
	var uncertain *SubmissionUncertainError
	if !errors.As(err, &uncertain) {
		t.Fatalf("error = %v", err)
	}
	if execution.State != casestore.ManualImportPrepared || execution.CommandID != nil {
		t.Fatalf("execution = %#v", execution)
	}
}

func newTestExecutor(
	t *testing.T,
	radarrClient *fakeRadarr,
	store *fakeStore,
	waiter *fakeWaiter,
	now time.Time,
) *Executor {
	t.Helper()
	executor, err := New(Dependencies{
		Radarr: radarrClient, Store: store, Clock: fixedClock{now: now},
		Waiter: waiter, PollInterval: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	return executor
}

func testAuthorization() decisionpolicy.AuthorizedManualImport {
	return decisionpolicy.AuthorizedManualImport{
		CaseID:       "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		CapabilityID: "capability:manual", FileID: "file:movie",
		ExpectedFingerprint: controller.FileFingerprint{
			Device: 1, Inode: 2, SizeBytes: 3, MTimeNS: 4,
		},
		ImportMode: controller.RadarrImportModeCopy,
		File: controller.RadarrManualImportCommandFile{
			Path:       "/downloads/Example.Movie.2026/movie.mkv",
			FolderName: "Example.Movie.2026", DownloadID: "ABCDEF0123456789",
			MovieID: 42,
			Quality: controller.RadarrQualityModel{
				Quality: controller.RadarrQuality{
					ID: 7, Name: "Bluray-1080p", Source: "bluray", Resolution: 1080,
				},
			},
			Languages: []controller.RadarrLanguage{{ID: 1, Name: "English"}},
		},
		ProbeDurationMS: 3_600_000,
	}
}

func importedFile(
	authorized decisionpolicy.AuthorizedManualImport,
	occurredAt time.Time,
) controller.RadarrImportedFile {
	return controller.RadarrImportedFile{
		HistoryID: 91, MovieFileID: 92, MovieID: authorized.File.MovieID,
		DownloadID: authorized.File.DownloadID, OccurredAt: occurredAt,
		DroppedPath:  authorized.File.Path,
		ImportedPath: "/movies/Example Movie (2026)/Example Movie.mkv",
	}
}

type fixedClock struct {
	now time.Time
}

func (clock fixedClock) Now() time.Time {
	return clock.now
}

type fakeWaiter struct {
	waits int
	err   error
}

func (waiter *fakeWaiter) Wait(context.Context, time.Duration) error {
	waiter.waits++
	return waiter.err
}

type fakeRadarr struct {
	requestCommand radarr.Command
	requestErr     error
	requested      decisionpolicy.AuthorizedManualImport
	requestCalls   int
	commands       []radarr.Command
	commandReads   int
	imports        [][]controller.RadarrImportedFile
	historyReads   int
}

func (client *fakeRadarr) RequestManualImport(
	_ context.Context,
	authorized decisionpolicy.AuthorizedManualImport,
) (radarr.Command, error) {
	client.requestCalls++
	client.requested = authorized
	return client.requestCommand, client.requestErr
}

func (client *fakeRadarr) ReadManualImportCommand(
	context.Context,
	int64,
) (radarr.Command, error) {
	index := client.commandReads
	client.commandReads++
	if len(client.commands) == 0 {
		return radarr.Command{}, errors.New("unexpected command read")
	}
	if index >= len(client.commands) {
		index = len(client.commands) - 1
	}
	return client.commands[index], nil
}

func (client *fakeRadarr) ReadImportedFiles(
	context.Context,
	int64,
	string,
) ([]controller.RadarrImportedFile, error) {
	index := client.historyReads
	client.historyReads++
	if len(client.imports) == 0 {
		return []controller.RadarrImportedFile{}, nil
	}
	if index >= len(client.imports) {
		index = len(client.imports) - 1
	}
	return append([]controller.RadarrImportedFile(nil), client.imports[index]...), nil
}

type fakeStore struct {
	found         bool
	execution     casestore.ManualImportExecution
	importedCalls int
	failedCalls   int
}

func (store *fakeStore) PrepareManualImport(
	authorized decisionpolicy.AuthorizedManualImport,
	preparedAt time.Time,
) (casestore.ManualImportExecution, bool, error) {
	if store.found {
		return store.execution, false, nil
	}
	store.found = true
	store.execution = casestore.ManualImportExecution{
		Version: casestore.ManualImportExecutionVersionV1,
		CaseID:  authorized.CaseID, CapabilityID: authorized.CapabilityID,
		FileID: authorized.FileID, ExpectedFingerprint: authorized.ExpectedFingerprint,
		State: casestore.ManualImportPrepared, PreparedAt: preparedAt, UpdatedAt: preparedAt,
	}
	return store.execution, true, nil
}

func (store *fakeStore) MarkManualImportRequested(
	_ string,
	commandID int64,
	updatedAt time.Time,
) (casestore.ManualImportExecution, bool, error) {
	store.execution.State = casestore.ManualImportRequested
	store.execution.CommandID = &commandID
	store.execution.UpdatedAt = updatedAt
	return store.execution, true, nil
}

func (store *fakeStore) MarkManualImportImported(
	_ decisionpolicy.AuthorizedManualImport,
	imported controller.RadarrImportedFile,
	updatedAt time.Time,
) (casestore.ManualImportExecution, bool, error) {
	store.importedCalls++
	store.execution.State = casestore.ManualImportImported
	store.execution.UpdatedAt = updatedAt
	store.execution.Confirmation = &casestore.ManualImportConfirmation{
		HistoryID: imported.HistoryID, MovieFileID: imported.MovieFileID,
		MovieID: imported.MovieID, DownloadID: imported.DownloadID,
		OccurredAt: imported.OccurredAt, DroppedPath: imported.DroppedPath,
		ImportedPath: imported.ImportedPath,
	}
	return store.execution, true, nil
}

func (store *fakeStore) MarkManualImportFailed(
	_ string,
	updatedAt time.Time,
) (casestore.ManualImportExecution, bool, error) {
	store.failedCalls++
	store.execution.State = casestore.ManualImportFailed
	store.execution.UpdatedAt = updatedAt
	return store.execution, true, nil
}

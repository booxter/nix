package joinimport

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

const (
	testCaseID     = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	testDownloadID = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	testJoinedPath = "/downloads/Movie.Release/radarr-repair-join.mkv"
)

func TestExecutorConfirmsExactJoinedFileImport(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.September, 13, 20, 0, 0, 500_000_000, time.UTC)
	store := newFakeStore(now)
	exact := importedFile(now.Truncate(time.Second))
	mismatch := exact
	mismatch.HistoryID++
	mismatch.DroppedPath = "/downloads/Movie.Release/other.mkv"
	old := exact
	old.HistoryID--
	radarrClient := &fakeRadarr{
		requestCommand: servarr.Command{
			ID: 92, Name: "ManualImport", Status: servarr.CommandQueued,
			Result: servarr.CommandResultUnknown,
		},
		commands: []servarr.Command{{
			ID: 92, Name: "ManualImport", Status: servarr.CommandCompleted,
			Result: servarr.CommandResultSuccessful,
		}},
		imports: [][]controller.RadarrImportedFile{{old}, {old, mismatch}, {old, exact}},
	}
	waiter := &fakeWaiter{}
	executor := newTestExecutor(t, store, radarrClient, waiter, now)

	execution, err := executor.Execute(context.Background(), testCaseID)
	if err != nil {
		t.Fatal(err)
	}
	if execution.State != casestore.JoinImported || execution.Confirmation == nil ||
		execution.Confirmation.HistoryID != exact.HistoryID {
		t.Fatalf("execution = %#v", execution)
	}
	wantImport := testImportCommand()
	if !reflect.DeepEqual(radarrClient.requested, wantImport) {
		t.Fatalf("requested importRequest = %#v", radarrClient.requested)
	}
	if radarrClient.requestCalls != 1 || radarrClient.commandReads != 1 ||
		radarrClient.historyReads != 3 || waiter.waits != 1 {
		t.Fatalf(
			"calls: request = %d, command = %d, history = %d, waits = %d",
			radarrClient.requestCalls,
			radarrClient.commandReads,
			radarrClient.historyReads,
			waiter.waits,
		)
	}
}

func TestExecutorNeverRepeatsUncertainImport(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.September, 13, 20, 0, 0, 0, time.UTC)
	store := newFakeStore(now)
	radarrClient := &fakeRadarr{requestErr: errors.New("response was lost")}
	executor := newTestExecutor(t, store, radarrClient, &fakeWaiter{}, now)

	execution, err := executor.Execute(context.Background(), testCaseID)
	assertUncertainSubmission(t, execution, err)
	if radarrClient.requestCalls != 1 || radarrClient.historyReads != 2 {
		t.Fatalf(
			"first calls: request = %d, history = %d",
			radarrClient.requestCalls,
			radarrClient.historyReads,
		)
	}

	radarrClient.requestErr = nil
	executor = newTestExecutor(t, store, radarrClient, &fakeWaiter{}, now)
	execution, err = executor.Execute(context.Background(), testCaseID)
	assertUncertainSubmission(t, execution, err)
	if radarrClient.requestCalls != 1 || radarrClient.historyReads != 3 {
		t.Fatalf(
			"restart calls: request = %d, history = %d",
			radarrClient.requestCalls,
			radarrClient.historyReads,
		)
	}

	radarrClient.imports = [][]controller.RadarrImportedFile{{
		importedFile(now.Add(time.Second)),
	}}
	execution, err = executor.Execute(context.Background(), testCaseID)
	if err != nil || execution.State != casestore.JoinImported {
		t.Fatalf("recovered execution = %#v, error = %v", execution, err)
	}
	if radarrClient.requestCalls != 1 {
		t.Fatalf("request calls after confirmation = %d", radarrClient.requestCalls)
	}
}

func TestExecutorResumesRequestedImport(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.September, 13, 20, 0, 0, 0, time.UTC)
	store := newFakeStore(now)
	commandID := int64(92)
	store.execution.State = casestore.JoinImportRequested
	store.execution.Import = &casestore.JoinImport{
		Command:         testImportCommand(),
		HistoryIDBefore: 92, PreparedAt: now.Add(-time.Minute), CommandID: &commandID,
	}
	radarrClient := &fakeRadarr{imports: [][]controller.RadarrImportedFile{{
		importedFile(now),
	}}}
	executor := newTestExecutor(t, store, radarrClient, &fakeWaiter{}, now)

	execution, err := executor.Execute(context.Background(), testCaseID)
	if err != nil || execution.State != casestore.JoinImported {
		t.Fatalf("execution = %#v, error = %v", execution, err)
	}
	if radarrClient.requestCalls != 0 || radarrClient.commandReads != 0 {
		t.Fatalf(
			"calls after restart: request = %d, command = %d",
			radarrClient.requestCalls,
			radarrClient.commandReads,
		)
	}
}

func TestExecutorRecordsDefiniteImportFailure(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.September, 13, 20, 0, 0, 0, time.UTC)
	store := newFakeStore(now)
	radarrClient := &fakeRadarr{
		requestCommand: servarr.Command{
			ID: 92, Name: "ManualImport", Status: servarr.CommandQueued,
			Result: servarr.CommandResultUnknown,
		},
		commands: []servarr.Command{{
			ID: 92, Name: "ManualImport", Status: servarr.CommandFailed,
			Result: servarr.CommandResultUnsuccessful,
		}},
	}
	executor := newTestExecutor(t, store, radarrClient, &fakeWaiter{}, now)

	execution, err := executor.Execute(context.Background(), testCaseID)
	if err != nil || execution.State != casestore.JoinImportFailed {
		t.Fatalf("execution = %#v, error = %v", execution, err)
	}
	if store.failedCalls != 1 {
		t.Fatalf("failed transitions = %d", store.failedCalls)
	}
}

func TestExecutorLeavesMismatchedHistoryUnconfirmed(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.September, 13, 20, 0, 0, 0, time.UTC)
	store := newFakeStore(now)
	mismatch := importedFile(now.Add(time.Second))
	mismatch.MovieID++
	radarrClient := &fakeRadarr{
		requestCommand: servarr.Command{
			ID: 92, Name: "ManualImport", Status: servarr.CommandQueued,
			Result: servarr.CommandResultUnknown,
		},
		commands: []servarr.Command{{
			ID: 92, Name: "ManualImport", Status: servarr.CommandCompleted,
			Result: servarr.CommandResultSuccessful,
		}},
		imports: [][]controller.RadarrImportedFile{{mismatch}},
	}
	waiter := &fakeWaiter{err: context.DeadlineExceeded}
	executor := newTestExecutor(t, store, radarrClient, waiter, now)

	execution, err := executor.Execute(context.Background(), testCaseID)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error = %v", err)
	}
	if execution.State != casestore.JoinImportRequested || store.importedCalls != 0 {
		t.Fatalf("execution = %#v, imported transitions = %d", execution, store.importedCalls)
	}
}

func assertUncertainSubmission(
	t *testing.T,
	execution casestore.JoinExecution,
	err error,
) {
	t.Helper()
	var uncertain *servarr.SubmissionUncertainError
	if !errors.As(err, &uncertain) {
		t.Fatalf("error = %v", err)
	}
	if execution.State != casestore.JoinImportPrepared || execution.Import == nil ||
		execution.Import.CommandID != nil {
		t.Fatalf("execution = %#v", execution)
	}
}

func newTestExecutor(
	t *testing.T,
	store *fakeStore,
	radarrClient *fakeRadarr,
	waiter *fakeWaiter,
	now time.Time,
) *Executor {
	t.Helper()
	executor, err := New(Dependencies{
		Radarr: radarrClient, Store: store, Paths: fixedPathResolver{},
		Clock: fixedClock{now: now}, Waiter: waiter, PollInterval: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	return executor
}

func importedFile(occurredAt time.Time) controller.RadarrImportedFile {
	return controller.RadarrImportedFile{
		HistoryID: 93, MovieFileID: 94, MovieID: 42, DownloadID: testDownloadID,
		OccurredAt: occurredAt, DroppedPath: testJoinedPath,
		ImportedPath: "/movies/Movie (2026)/Movie.mkv",
	}
}

type fixedClock struct {
	now time.Time
}

func (clock fixedClock) Now() time.Time {
	return clock.now
}

type fixedPathResolver struct{}

func (fixedPathResolver) ResolvePublishedPath(
	rootID string,
	components []string,
) (string, error) {
	if rootID != "root:downloads" ||
		!reflect.DeepEqual(components, []string{"Movie.Release", "radarr-repair-join.mkv"}) {
		return "", errors.New("unexpected published path")
	}
	return testJoinedPath, nil
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
	requestCommand servarr.Command
	requestErr     error
	requested      controller.RadarrManualImportCommand
	requestCalls   int
	commands       []servarr.Command
	commandReads   int
	imports        [][]controller.RadarrImportedFile
	historyReads   int
}

func (client *fakeRadarr) RequestManualImport(
	_ context.Context,
	importRequest controller.RadarrManualImportCommand,
) (servarr.Command, error) {
	client.requestCalls++
	client.requested = importRequest
	return client.requestCommand, client.requestErr
}

func (client *fakeRadarr) ReadManualImportCommand(
	context.Context,
	int64,
) (servarr.Command, error) {
	index := client.commandReads
	client.commandReads++
	if len(client.commands) == 0 {
		return servarr.Command{}, errors.New("unexpected command read")
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
	record        casestore.CaseRecord
	execution     casestore.JoinExecution
	importedCalls int
	failedCalls   int
}

func newFakeStore(now time.Time) *fakeStore {
	movieID := int64(42)
	return &fakeStore{
		record: casestore.CaseRecord{
			CaseID: testCaseID,
			Snapshot: casebuilder.LocalSnapshot{Observation: casebuilder.Observation{
				Correlation: controller.DownloadCorrelation{Radarr: controller.RadarrQueueRecord{
					MovieID: &movieID, DownloadID: testDownloadID,
				}},
				Movie:   &controller.RadarrMovie{ID: 42},
				History: []controller.RadarrHistoryEvent{testGrab()},
			}},
		},
		execution: casestore.JoinExecution{
			Authorization: decisionpolicy.AuthorizedJoin{CaseID: testCaseID},
			State:         casestore.JoinPublished,
			PreparedAt:    now.Add(-time.Minute),
			UpdatedAt:     now.Add(-time.Second),
			Published: &casestore.JoinPublishedArtifact{
				RootID: "root:downloads",
				PathComponents: []string{
					"Movie.Release",
					"radarr-repair-join.mkv",
				},
			},
		},
	}
}

func (store *fakeStore) Get(string) (casestore.CaseRecord, bool, error) {
	return store.record, true, nil
}

func (store *fakeStore) GetJoinExecution(string) (casestore.JoinExecution, bool, error) {
	return store.execution, true, nil
}

func (store *fakeStore) PrepareJoinImport(
	_ string,
	request casestore.JoinImportRequest,
	preparedAt time.Time,
) (casestore.JoinExecution, bool, error) {
	if store.execution.State != casestore.JoinPublished {
		return store.execution, false, nil
	}
	store.execution.State = casestore.JoinImportPrepared
	store.execution.Import = &casestore.JoinImport{
		Command:         request.Command,
		HistoryIDBefore: request.HistoryIDBefore, PreparedAt: preparedAt,
	}
	store.execution.UpdatedAt = preparedAt
	return store.execution, true, nil
}

func testImportCommand() controller.RadarrManualImportCommand {
	return controller.RadarrManualImportCommand{
		ImportMode: controller.RadarrImportModeCopy,
		File: controller.RadarrManualImportCommandFile{
			Path: testJoinedPath,
			Quality: controller.RadarrQualityModel{Quality: controller.RadarrQuality{
				ID: 7, Name: "Bluray-1080p", Source: "bluray",
				Resolution: 1080, Modifier: "none",
			}},
			Languages:  []controller.RadarrLanguage{{ID: 1, Name: "English"}},
			DownloadID: testDownloadID,
			MovieID:    42,
		},
	}
}

func testGrab() controller.RadarrHistoryEvent {
	command := testImportCommand()
	return controller.RadarrHistoryEvent{
		ID: 91, MovieID: command.File.MovieID, DownloadID: command.File.DownloadID,
		EventType:  controller.RadarrHistoryEventGrabbed,
		OccurredAt: time.Date(2026, time.September, 1, 12, 0, 0, 0, time.UTC),
		Quality:    &command.File.Quality,
		Languages:  command.File.Languages,
	}
}

func (store *fakeStore) MarkJoinImportRequested(
	_ string,
	commandID int64,
	updatedAt time.Time,
) (casestore.JoinExecution, bool, error) {
	store.execution.State = casestore.JoinImportRequested
	store.execution.Import.CommandID = &commandID
	store.execution.UpdatedAt = updatedAt
	return store.execution, true, nil
}

func (store *fakeStore) MarkJoinImported(
	_ string,
	imported controller.RadarrImportedFile,
	updatedAt time.Time,
) (casestore.JoinExecution, bool, error) {
	store.importedCalls++
	store.execution.State = casestore.JoinImported
	store.execution.Confirmation = &casestore.RadarrImportConfirmation{
		HistoryID: imported.HistoryID, MovieFileID: imported.MovieFileID,
		MovieID: imported.MovieID, DownloadID: imported.DownloadID,
		OccurredAt: imported.OccurredAt, DroppedPath: imported.DroppedPath,
		ImportedPath: imported.ImportedPath,
	}
	store.execution.UpdatedAt = updatedAt
	return store.execution, true, nil
}

func (store *fakeStore) MarkJoinImportFailed(
	_ string,
	updatedAt time.Time,
) (casestore.JoinExecution, bool, error) {
	store.failedCalls++
	store.execution.State = casestore.JoinImportFailed
	store.execution.UpdatedAt = updatedAt
	return store.execution, true, nil
}

package joinimport

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/radarr"
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
		requestCommand: radarr.Command{
			ID: 92, Name: "DownloadedMoviesScan", Status: radarr.CommandQueued,
			Result: radarr.CommandResultUnknown,
		},
		commands: []radarr.Command{{
			ID: 92, Name: "DownloadedMoviesScan", Status: radarr.CommandCompleted,
			Result: radarr.CommandResultSuccessful,
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
	wantScan := radarr.DownloadedMoviesScan{
		Path: testJoinedPath, DownloadID: testDownloadID,
	}
	if !reflect.DeepEqual(radarrClient.requested, wantScan) {
		t.Fatalf("requested scan = %#v", radarrClient.requested)
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

func TestExecutorNeverRepeatsUncertainScan(t *testing.T) {
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

func TestExecutorResumesRequestedScan(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.September, 13, 20, 0, 0, 0, time.UTC)
	store := newFakeStore(now)
	commandID := int64(92)
	store.execution.State = casestore.JoinScanRequested
	store.execution.Scan = &casestore.JoinScan{
		Path: testJoinedPath, MovieID: 42, DownloadID: testDownloadID,
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

func TestExecutorRecordsDefiniteScanFailure(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.September, 13, 20, 0, 0, 0, time.UTC)
	store := newFakeStore(now)
	radarrClient := &fakeRadarr{
		requestCommand: radarr.Command{
			ID: 92, Name: "DownloadedMoviesScan", Status: radarr.CommandQueued,
			Result: radarr.CommandResultUnknown,
		},
		commands: []radarr.Command{{
			ID: 92, Name: "DownloadedMoviesScan", Status: radarr.CommandFailed,
			Result: radarr.CommandResultUnsuccessful,
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
		requestCommand: radarr.Command{
			ID: 92, Name: "DownloadedMoviesScan", Status: radarr.CommandQueued,
			Result: radarr.CommandResultUnknown,
		},
		commands: []radarr.Command{{
			ID: 92, Name: "DownloadedMoviesScan", Status: radarr.CommandCompleted,
			Result: radarr.CommandResultSuccessful,
		}},
		imports: [][]controller.RadarrImportedFile{{mismatch}},
	}
	waiter := &fakeWaiter{err: context.DeadlineExceeded}
	executor := newTestExecutor(t, store, radarrClient, waiter, now)

	execution, err := executor.Execute(context.Background(), testCaseID)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error = %v", err)
	}
	if execution.State != casestore.JoinScanRequested || store.importedCalls != 0 {
		t.Fatalf("execution = %#v, imported transitions = %d", execution, store.importedCalls)
	}
}

func assertUncertainSubmission(
	t *testing.T,
	execution casestore.JoinExecution,
	err error,
) {
	t.Helper()
	var uncertain *SubmissionUncertainError
	if !errors.As(err, &uncertain) {
		t.Fatalf("error = %v", err)
	}
	if execution.State != casestore.JoinScanPrepared || execution.Scan == nil ||
		execution.Scan.CommandID != nil {
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
	requestCommand radarr.Command
	requestErr     error
	requested      radarr.DownloadedMoviesScan
	requestCalls   int
	commands       []radarr.Command
	commandReads   int
	imports        [][]controller.RadarrImportedFile
	historyReads   int
}

func (client *fakeRadarr) RequestDownloadedMoviesScan(
	_ context.Context,
	scan radarr.DownloadedMoviesScan,
) (radarr.Command, error) {
	client.requestCalls++
	client.requested = scan
	return client.requestCommand, client.requestErr
}

func (client *fakeRadarr) ReadDownloadedMoviesScanCommand(
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

func (store *fakeStore) PrepareJoinScan(
	_ string,
	request casestore.JoinScanRequest,
	preparedAt time.Time,
) (casestore.JoinExecution, bool, error) {
	if store.execution.State != casestore.JoinPublished {
		return store.execution, false, nil
	}
	store.execution.State = casestore.JoinScanPrepared
	store.execution.Scan = &casestore.JoinScan{
		Path: request.Path, MovieID: request.MovieID, DownloadID: request.DownloadID,
		HistoryIDBefore: request.HistoryIDBefore, PreparedAt: preparedAt,
	}
	store.execution.UpdatedAt = preparedAt
	return store.execution, true, nil
}

func (store *fakeStore) MarkJoinScanRequested(
	_ string,
	commandID int64,
	updatedAt time.Time,
) (casestore.JoinExecution, bool, error) {
	store.execution.State = casestore.JoinScanRequested
	store.execution.Scan.CommandID = &commandID
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

package publishedimport

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/radarr"
	"github.com/booxter/nix-config/radarr-repair/internal/servarr"
)

type State string

const (
	Published       State = "artifact_published"
	ImportPrepared  State = "import_prepared"
	ImportRequested State = "import_requested"
	Imported        State = "imported"
	ImportFailed    State = "import_failed"
)

type Artifact struct {
	RootID         string
	PathComponents []string
}

type Execution struct {
	CaseID       string
	State        State
	Published    *Artifact
	Import       *casestore.JoinImport
	Confirmation *casestore.RadarrImportConfirmation
}

type Radarr interface {
	RequestManualImport(context.Context, controller.RadarrManualImportCommand) (servarr.Command, error)
	ReadManualImportCommand(context.Context, int64) (servarr.Command, error)
	ReadImportedFiles(context.Context, int64, string) ([]controller.RadarrImportedFile, error)
}

type Store interface {
	Get(string) (casestore.CaseRecord, bool, error)
	GetExecution(string) (Execution, bool, error)
	PrepareImport(
		string,
		casestore.JoinImportRequest,
		time.Time,
	) (Execution, bool, error)
	MarkImportRequested(string, int64, time.Time) (Execution, bool, error)
	MarkImported(
		string,
		controller.RadarrImportedFile,
		time.Time,
	) (Execution, bool, error)
	MarkImportFailed(string, time.Time) (Execution, bool, error)
}

type PublishedPathResolver interface {
	ResolvePublishedPath(string, []string) (string, error)
}

type Dependencies struct {
	Radarr       Radarr
	Store        Store
	Paths        PublishedPathResolver
	Clock        controller.Clock
	Waiter       servarr.Waiter
	PollInterval time.Duration
}

type Executor struct {
	dependencies Dependencies
}

func New(dependencies Dependencies) (*Executor, error) {
	switch {
	case dependencies.Radarr == nil:
		return nil, fmt.Errorf("Radarr published-file importer is required")
	case dependencies.Store == nil:
		return nil, fmt.Errorf("published-file import store is required")
	case dependencies.Paths == nil:
		return nil, fmt.Errorf("published path resolver is required")
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("published-file import clock is required")
	case dependencies.Waiter == nil:
		return nil, fmt.Errorf("published-file import poll waiter is required")
	case dependencies.PollInterval <= 0:
		return nil, fmt.Errorf("published-file import poll interval must be positive")
	default:
		return &Executor{dependencies: dependencies}, nil
	}
}

func (executor *Executor) Execute(
	ctx context.Context,
	caseID string,
) (Execution, error) {
	if executor == nil {
		return Execution{}, fmt.Errorf("published-file import executor is not configured")
	}
	if err := ctx.Err(); err != nil {
		return Execution{}, err
	}
	execution, found, err := executor.dependencies.Store.GetExecution(caseID)
	if err != nil {
		return Execution{}, fmt.Errorf("read published-file execution: %w", err)
	}
	if !found {
		return Execution{}, fmt.Errorf("published artifact for case %q is not prepared", caseID)
	}

	switch execution.State {
	case Published:
		return executor.prepareAndSubmit(ctx, caseID, execution)
	case ImportPrepared, ImportRequested, Imported, ImportFailed:
		return executor.run(ctx, execution, false)
	default:
		return execution, fmt.Errorf(
			"published artifact state %q is not ready for Radarr import",
			execution.State,
		)
	}
}

func (executor *Executor) prepareAndSubmit(
	ctx context.Context,
	caseID string,
	execution Execution,
) (Execution, error) {
	request, err := executor.importRequest(caseID, execution)
	if err != nil {
		return execution, err
	}
	imports, err := executor.dependencies.Radarr.ReadImportedFiles(
		ctx,
		request.Command.File.MovieID,
		request.Command.File.DownloadID,
	)
	if err != nil {
		return execution, fmt.Errorf(
			"read Radarr imported-file history before published-file import: %w",
			err,
		)
	}
	request.HistoryIDBefore = radarr.HighestImportedFileHistoryID(imports)
	preparedAt, err := executor.now()
	if err != nil {
		return execution, err
	}
	execution, prepared, err := executor.dependencies.Store.PrepareImport(
		caseID,
		request,
		preparedAt,
	)
	if err != nil {
		return execution, fmt.Errorf("prepare Radarr published-file import: %w", err)
	}
	return executor.run(ctx, execution, prepared)
}

func (executor *Executor) run(
	ctx context.Context,
	execution Execution,
	newlyPrepared bool,
) (Execution, error) {
	if execution.Import == nil {
		return execution, fmt.Errorf("published-file import has no prepared Radarr request")
	}
	flow, err := servarr.NewImportExecution(
		servarr.ImportExecutionDependencies[Execution]{
			Service: "Radarr", Operation: "published-file import",
			Clock: executor.dependencies.Clock, Waiter: executor.dependencies.Waiter,
			PollInterval: executor.dependencies.PollInterval, RequireCompletionResult: true,
			CaseID: func(current Execution) string { return current.CaseID },
			State:  publishedImportState,
			CommandID: func(current Execution) (int64, bool) {
				if current.Import == nil || current.Import.CommandID == nil {
					return 0, false
				}
				return *current.Import.CommandID, true
			},
			Submit: func(ctx context.Context) (servarr.Command, error) {
				return executor.dependencies.Radarr.RequestManualImport(
					ctx,
					execution.Import.Command,
				)
			},
			ReadCommand: executor.dependencies.Radarr.ReadManualImportCommand,
			Confirm:     executor.confirm,
			MarkRequested: func(current Execution, commandID int64, at time.Time) (Execution, error) {
				updated, _, markErr := executor.dependencies.Store.MarkImportRequested(
					current.CaseID,
					commandID,
					at,
				)
				return updated, markErr
			},
			MarkFailed: func(current Execution, at time.Time) (Execution, error) {
				updated, _, markErr := executor.dependencies.Store.MarkImportFailed(current.CaseID, at)
				return updated, markErr
			},
		},
	)
	if err != nil {
		return execution, err
	}
	return flow.Run(ctx, execution, newlyPrepared)
}

func publishedImportState(execution Execution) (servarr.ImportExecutionState, error) {
	switch execution.State {
	case ImportPrepared:
		return servarr.ImportPrepared, nil
	case ImportRequested:
		return servarr.ImportRequested, nil
	case Imported:
		return servarr.ImportConfirmed, nil
	case ImportFailed:
		return servarr.ImportFailed, nil
	default:
		return 0, fmt.Errorf("unknown published-file import state %q", execution.State)
	}
}

func (executor *Executor) confirm(
	ctx context.Context,
	execution Execution,
) (Execution, bool, error) {
	if execution.Import == nil {
		return execution, false, fmt.Errorf("published-file import has no prepared Radarr request")
	}
	file := execution.Import.Command.File
	imports, err := executor.dependencies.Radarr.ReadImportedFiles(
		ctx,
		file.MovieID,
		file.DownloadID,
	)
	if err != nil {
		return execution, false, fmt.Errorf("read Radarr imported-file history: %w", err)
	}
	imported, found := radarr.FindImportedFile(imports, radarr.ImportedFileMatch{
		MovieID: file.MovieID, DownloadID: file.DownloadID,
		DroppedPath:    file.Path,
		AfterHistoryID: execution.Import.HistoryIDBefore,
	})
	if !found {
		return execution, false, nil
	}
	confirmedAt, err := executor.now()
	if err != nil {
		return execution, false, err
	}
	confirmed, _, err := executor.dependencies.Store.MarkImported(
		execution.CaseID,
		imported,
		confirmedAt,
	)
	if err != nil {
		return execution, false, fmt.Errorf("record confirmed Radarr published-file import: %w", err)
	}
	return confirmed, true, nil
}

func (executor *Executor) importRequest(
	caseID string,
	execution Execution,
) (casestore.JoinImportRequest, error) {
	if execution.Published == nil {
		return casestore.JoinImportRequest{}, fmt.Errorf("published artifact has no destination")
	}
	record, found, err := executor.dependencies.Store.Get(caseID)
	if err != nil {
		return casestore.JoinImportRequest{}, fmt.Errorf("read published-file case: %w", err)
	}
	if !found {
		return casestore.JoinImportRequest{}, fmt.Errorf("case %q is not stored", caseID)
	}
	queue := record.Snapshot.Observation.Correlation.Radarr
	if queue.MovieID == nil || *queue.MovieID <= 0 {
		return casestore.JoinImportRequest{}, fmt.Errorf("published-file case has no Radarr movie ID")
	}
	path, err := executor.dependencies.Paths.ResolvePublishedPath(
		execution.Published.RootID,
		execution.Published.PathComponents,
	)
	if err != nil {
		return casestore.JoinImportRequest{}, fmt.Errorf("resolve published file: %w", err)
	}
	command, complete := controller.BuildRadarrPublishedFileImport(
		path,
		*queue.MovieID,
		queue.DownloadID,
		record.Snapshot.Observation.History,
	)
	if !complete {
		return casestore.JoinImportRequest{}, fmt.Errorf(
			"published-file case has no complete matching grab metadata",
		)
	}
	return casestore.JoinImportRequest{
		Command: command,
	}, nil
}

func (executor *Executor) now() (time.Time, error) {
	now := executor.dependencies.Clock.Now().UTC()
	if now.IsZero() {
		return time.Time{}, fmt.Errorf("published-file import clock returned a zero time")
	}
	return now, nil
}

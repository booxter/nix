package manualimport

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/radarr"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

type Radarr interface {
	RequestManualImport(
		context.Context,
		controller.RadarrManualImportCommand,
	) (servarr.Command, error)
	ReadManualImportCommand(context.Context, int64) (servarr.Command, error)
	ReadImportedFiles(context.Context, int64, string) ([]controller.RadarrImportedFile, error)
}

type Store interface {
	PrepareManualImport(
		decisionpolicy.AuthorizedManualImport,
		int64,
		time.Time,
	) (casestore.ManualImportExecution, bool, error)
	MarkManualImportRequested(
		string,
		int64,
		time.Time,
	) (casestore.ManualImportExecution, bool, error)
	MarkManualImportImported(
		decisionpolicy.AuthorizedManualImport,
		controller.RadarrImportedFile,
		time.Time,
	) (casestore.ManualImportExecution, bool, error)
	MarkManualImportFailed(
		string,
		time.Time,
	) (casestore.ManualImportExecution, bool, error)
}

type Dependencies struct {
	Radarr       Radarr
	Store        Store
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
		return nil, fmt.Errorf("Radarr manual importer is required")
	case dependencies.Store == nil:
		return nil, fmt.Errorf("manual-import execution store is required")
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("manual-import execution clock is required")
	case dependencies.Waiter == nil:
		return nil, fmt.Errorf("manual-import poll waiter is required")
	case dependencies.PollInterval <= 0:
		return nil, fmt.Errorf("manual-import poll interval must be positive")
	default:
		return &Executor{dependencies: dependencies}, nil
	}
}

func (executor *Executor) Execute(
	ctx context.Context,
	authorized decisionpolicy.AuthorizedManualImport,
) (casestore.ManualImportExecution, error) {
	if executor == nil {
		return casestore.ManualImportExecution{}, fmt.Errorf("manual-import executor is not configured")
	}
	if err := ctx.Err(); err != nil {
		return casestore.ManualImportExecution{}, err
	}
	imports, err := executor.dependencies.Radarr.ReadImportedFiles(
		ctx,
		authorized.File.MovieID,
		authorized.File.DownloadID,
	)
	if err != nil {
		return casestore.ManualImportExecution{}, fmt.Errorf(
			"read Radarr imported-file history before manual import: %w",
			err,
		)
	}
	preparedAt, err := executor.now()
	if err != nil {
		return casestore.ManualImportExecution{}, err
	}
	execution, prepared, err := executor.dependencies.Store.PrepareManualImport(
		authorized,
		radarr.HighestImportedFileHistoryID(imports),
		preparedAt,
	)
	if err != nil {
		return casestore.ManualImportExecution{}, fmt.Errorf("prepare manual import: %w", err)
	}
	return executor.run(ctx, authorized, execution, prepared)
}

func (executor *Executor) run(
	ctx context.Context,
	authorized decisionpolicy.AuthorizedManualImport,
	execution casestore.ManualImportExecution,
	newlyPrepared bool,
) (casestore.ManualImportExecution, error) {
	flow, err := servarr.NewImportExecution(
		servarr.ImportExecutionDependencies[casestore.ManualImportExecution]{
			Service: "Radarr", Operation: "manual-import", Clock: executor.dependencies.Clock,
			Waiter: executor.dependencies.Waiter, PollInterval: executor.dependencies.PollInterval,
			RequireCompletionResult: true,
			CaseID:                  func(current casestore.ManualImportExecution) string { return current.CaseID },
			State:                   manualImportState,
			CommandID: func(current casestore.ManualImportExecution) (int64, bool) {
				if current.CommandID == nil {
					return 0, false
				}
				return *current.CommandID, true
			},
			Submit: func(ctx context.Context) (servarr.Command, error) {
				return executor.dependencies.Radarr.RequestManualImport(
					ctx,
					controller.RadarrManualImportCommand{
						ImportMode: authorized.ImportMode,
						File:       authorized.File,
					},
				)
			},
			ReadCommand: executor.dependencies.Radarr.ReadManualImportCommand,
			Confirm: func(
				ctx context.Context,
				current casestore.ManualImportExecution,
			) (casestore.ManualImportExecution, bool, error) {
				return executor.confirm(ctx, authorized, current)
			},
			MarkRequested: func(
				current casestore.ManualImportExecution,
				commandID int64,
				at time.Time,
			) (casestore.ManualImportExecution, error) {
				updated, _, markErr := executor.dependencies.Store.MarkManualImportRequested(
					current.CaseID,
					commandID,
					at,
				)
				return updated, markErr
			},
			MarkFailed: func(
				current casestore.ManualImportExecution,
				at time.Time,
			) (casestore.ManualImportExecution, error) {
				updated, _, markErr := executor.dependencies.Store.MarkManualImportFailed(
					current.CaseID,
					at,
				)
				return updated, markErr
			},
		},
	)
	if err != nil {
		return execution, err
	}
	return flow.Run(ctx, execution, newlyPrepared)
}

func manualImportState(
	execution casestore.ManualImportExecution,
) (servarr.ImportExecutionState, error) {
	switch execution.State {
	case casestore.ManualImportPrepared:
		return servarr.ImportPrepared, nil
	case casestore.ManualImportRequested:
		return servarr.ImportRequested, nil
	case casestore.ManualImportImported:
		return servarr.ImportConfirmed, nil
	case casestore.ManualImportFailed:
		return servarr.ImportFailed, nil
	default:
		return 0, fmt.Errorf("unknown manual-import execution state %q", execution.State)
	}
}

func (executor *Executor) confirm(
	ctx context.Context,
	authorized decisionpolicy.AuthorizedManualImport,
	execution casestore.ManualImportExecution,
) (casestore.ManualImportExecution, bool, error) {
	imports, err := executor.dependencies.Radarr.ReadImportedFiles(
		ctx,
		authorized.File.MovieID,
		authorized.File.DownloadID,
	)
	if err != nil {
		return execution, false, fmt.Errorf("read Radarr imported-file history: %w", err)
	}
	imported, found := radarr.FindImportedFile(imports, radarr.ImportedFileMatch{
		MovieID: authorized.File.MovieID, DownloadID: authorized.File.DownloadID,
		DroppedPath: authorized.File.Path, AfterHistoryID: execution.HistoryIDBefore,
	})
	if !found {
		return execution, false, nil
	}
	confirmedAt, err := executor.now()
	if err != nil {
		return execution, false, err
	}
	confirmed, _, err := executor.dependencies.Store.MarkManualImportImported(
		authorized,
		imported,
		confirmedAt,
	)
	if err != nil {
		return execution, false, fmt.Errorf("record confirmed Radarr manual import: %w", err)
	}
	return confirmed, true, nil
}

func (executor *Executor) now() (time.Time, error) {
	now := executor.dependencies.Clock.Now().UTC()
	if now.IsZero() {
		return time.Time{}, fmt.Errorf("clock returned a zero time")
	}
	return now, nil
}

package manualimport

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/radarr"
)

type Radarr interface {
	RequestManualImport(
		context.Context,
		decisionpolicy.AuthorizedManualImport,
	) (radarr.Command, error)
	ReadManualImportCommand(context.Context, int64) (radarr.Command, error)
	ReadImportedFiles(context.Context, int64, string) ([]controller.RadarrImportedFile, error)
}

type Store interface {
	PrepareManualImport(
		decisionpolicy.AuthorizedManualImport,
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

type Waiter interface {
	Wait(context.Context, time.Duration) error
}

type Timer struct{}

func (Timer) Wait(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

type Dependencies struct {
	Radarr       Radarr
	Store        Store
	Clock        controller.Clock
	Waiter       Waiter
	PollInterval time.Duration
}

type Executor struct {
	dependencies Dependencies
}

type commandDisposition uint8

const (
	commandWaiting commandDisposition = iota + 1
	commandFailed
)

type SubmissionUncertainError struct {
	CaseID string
	cause  error
}

func (failure *SubmissionUncertainError) Error() string {
	message := fmt.Sprintf(
		"Radarr manual-import submission for case %q may have succeeded; refusing to repeat it",
		failure.CaseID,
	)
	if failure.cause != nil {
		return fmt.Sprintf("%s: %v", message, failure.cause)
	}
	return message
}

func (failure *SubmissionUncertainError) Unwrap() error {
	return failure.cause
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
	preparedAt, err := executor.now()
	if err != nil {
		return casestore.ManualImportExecution{}, err
	}
	execution, prepared, err := executor.dependencies.Store.PrepareManualImport(
		authorized,
		preparedAt,
	)
	if err != nil {
		return casestore.ManualImportExecution{}, fmt.Errorf("prepare manual import: %w", err)
	}
	if !prepared {
		return executor.resume(ctx, authorized, execution)
	}

	command, err := executor.dependencies.Radarr.RequestManualImport(ctx, authorized)
	if err != nil {
		confirmed, confirmErr := executor.confirm(ctx, authorized, execution)
		if confirmed.State == casestore.ManualImportImported {
			return confirmed, confirmErr
		}
		return execution, &SubmissionUncertainError{
			CaseID: authorized.CaseID,
			cause: errors.Join(
				fmt.Errorf("request Radarr manual import: %w", err),
				confirmErr,
			),
		}
	}
	requestedAt, err := executor.now()
	if err != nil {
		return execution, &SubmissionUncertainError{CaseID: authorized.CaseID, cause: err}
	}
	execution, _, err = executor.dependencies.Store.MarkManualImportRequested(
		authorized.CaseID,
		command.ID,
		requestedAt,
	)
	if err != nil {
		return execution, &SubmissionUncertainError{
			CaseID: authorized.CaseID,
			cause:  fmt.Errorf("record Radarr manual-import command: %w", err),
		}
	}
	return executor.follow(ctx, authorized, execution)
}

func (executor *Executor) resume(
	ctx context.Context,
	authorized decisionpolicy.AuthorizedManualImport,
	execution casestore.ManualImportExecution,
) (casestore.ManualImportExecution, error) {
	switch execution.State {
	case casestore.ManualImportImported, casestore.ManualImportFailed:
		return execution, nil
	case casestore.ManualImportRequested:
		return executor.follow(ctx, authorized, execution)
	case casestore.ManualImportPrepared:
		confirmed, err := executor.confirm(ctx, authorized, execution)
		if confirmed.State == casestore.ManualImportImported {
			return confirmed, err
		}
		return execution, &SubmissionUncertainError{
			CaseID: authorized.CaseID,
			cause:  err,
		}
	default:
		return execution, fmt.Errorf("unknown manual-import execution state %q", execution.State)
	}
}

func (executor *Executor) follow(
	ctx context.Context,
	authorized decisionpolicy.AuthorizedManualImport,
	execution casestore.ManualImportExecution,
) (casestore.ManualImportExecution, error) {
	if execution.CommandID == nil {
		return execution, fmt.Errorf("requested manual import has no Radarr command ID")
	}
	for {
		confirmed, err := executor.confirm(ctx, authorized, execution)
		if err != nil || confirmed.State == casestore.ManualImportImported {
			return confirmed, err
		}

		command, err := executor.dependencies.Radarr.ReadManualImportCommand(
			ctx,
			*execution.CommandID,
		)
		if err != nil {
			return execution, fmt.Errorf("read Radarr manual-import command: %w", err)
		}
		disposition, err := classifyCommand(command)
		if err != nil {
			return execution, err
		}
		if disposition == commandFailed {
			failedAt, nowErr := executor.now()
			if nowErr != nil {
				return execution, nowErr
			}
			execution, _, err = executor.dependencies.Store.MarkManualImportFailed(
				authorized.CaseID,
				failedAt,
			)
			if err != nil {
				return execution, fmt.Errorf("record failed Radarr manual import: %w", err)
			}
			return execution, nil
		}
		if err := executor.dependencies.Waiter.Wait(
			ctx,
			executor.dependencies.PollInterval,
		); err != nil {
			return execution, err
		}
	}
}

func (executor *Executor) confirm(
	ctx context.Context,
	authorized decisionpolicy.AuthorizedManualImport,
	execution casestore.ManualImportExecution,
) (casestore.ManualImportExecution, error) {
	imports, err := executor.dependencies.Radarr.ReadImportedFiles(
		ctx,
		authorized.File.MovieID,
		authorized.File.DownloadID,
	)
	if err != nil {
		return execution, fmt.Errorf("read Radarr imported-file history: %w", err)
	}
	imported, found := matchingImport(imports, authorized, execution.PreparedAt)
	if !found {
		return execution, nil
	}
	confirmedAt, err := executor.now()
	if err != nil {
		return execution, err
	}
	confirmed, _, err := executor.dependencies.Store.MarkManualImportImported(
		authorized,
		imported,
		confirmedAt,
	)
	if err != nil {
		return execution, fmt.Errorf("record confirmed Radarr manual import: %w", err)
	}
	return confirmed, nil
}

func (executor *Executor) now() (time.Time, error) {
	now := executor.dependencies.Clock.Now().UTC()
	if now.IsZero() {
		return time.Time{}, fmt.Errorf("clock returned a zero time")
	}
	return now, nil
}

func matchingImport(
	imports []controller.RadarrImportedFile,
	authorized decisionpolicy.AuthorizedManualImport,
	preparedAt time.Time,
) (controller.RadarrImportedFile, bool) {
	var selected controller.RadarrImportedFile
	found := false
	for _, imported := range imports {
		if imported.MovieID != authorized.File.MovieID ||
			imported.DownloadID != authorized.File.DownloadID ||
			imported.DroppedPath != authorized.File.Path ||
			!imported.OccurredAt.After(preparedAt) {
			continue
		}
		if !found || imported.OccurredAt.Before(selected.OccurredAt) ||
			(imported.OccurredAt.Equal(selected.OccurredAt) && imported.HistoryID < selected.HistoryID) {
			selected = imported
			found = true
		}
	}
	return selected, found
}

func classifyCommand(command radarr.Command) (commandDisposition, error) {
	switch command.Status {
	case radarr.CommandQueued, radarr.CommandStarted:
		if command.Result != "" && command.Result != radarr.CommandResultUnknown {
			return 0, fmt.Errorf(
				"active Radarr manual-import command has unexpected result %q",
				command.Result,
			)
		}
		return commandWaiting, nil
	case radarr.CommandCompleted:
		switch command.Result {
		case radarr.CommandResultSuccessful:
			return commandWaiting, nil
		case radarr.CommandResultUnsuccessful:
			return commandFailed, nil
		default:
			return 0, fmt.Errorf(
				"completed Radarr manual-import command has unexpected result %q",
				command.Result,
			)
		}
	case radarr.CommandFailed, radarr.CommandAborted, radarr.CommandCancelled, radarr.CommandOrphaned:
		return commandFailed, nil
	default:
		return 0, fmt.Errorf(
			"Radarr manual-import command has unknown status %q",
			command.Status,
		)
	}
}

package joinimport

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/radarr"
)

type Radarr interface {
	RequestDownloadedMoviesScan(context.Context, radarr.DownloadedMoviesScan) (radarr.Command, error)
	ReadDownloadedMoviesScanCommand(context.Context, int64) (radarr.Command, error)
	ReadImportedFiles(context.Context, int64, string) ([]controller.RadarrImportedFile, error)
}

type Store interface {
	Get(string) (casestore.CaseRecord, bool, error)
	GetJoinExecution(string) (casestore.JoinExecution, bool, error)
	PrepareJoinScan(
		string,
		casestore.JoinScanRequest,
		time.Time,
	) (casestore.JoinExecution, bool, error)
	MarkJoinScanRequested(string, int64, time.Time) (casestore.JoinExecution, bool, error)
	MarkJoinImported(
		string,
		controller.RadarrImportedFile,
		time.Time,
	) (casestore.JoinExecution, bool, error)
	MarkJoinImportFailed(string, time.Time) (casestore.JoinExecution, bool, error)
}

type PublishedPathResolver interface {
	ResolvePublishedPath(string, []string) (string, error)
}

type Waiter interface {
	Wait(context.Context, time.Duration) error
}

type Dependencies struct {
	Radarr       Radarr
	Store        Store
	Paths        PublishedPathResolver
	Clock        controller.Clock
	Waiter       Waiter
	PollInterval time.Duration
}

type Executor struct {
	dependencies Dependencies
}

type SubmissionUncertainError struct {
	CaseID string
	cause  error
}

func (failure *SubmissionUncertainError) Error() string {
	message := fmt.Sprintf(
		"Radarr joined-file scan for case %q may have succeeded; refusing to repeat it",
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
		return nil, fmt.Errorf("Radarr joined-file importer is required")
	case dependencies.Store == nil:
		return nil, fmt.Errorf("joined-file import store is required")
	case dependencies.Paths == nil:
		return nil, fmt.Errorf("published path resolver is required")
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("joined-file import clock is required")
	case dependencies.Waiter == nil:
		return nil, fmt.Errorf("joined-file import poll waiter is required")
	case dependencies.PollInterval <= 0:
		return nil, fmt.Errorf("joined-file import poll interval must be positive")
	default:
		return &Executor{dependencies: dependencies}, nil
	}
}

func (executor *Executor) Execute(
	ctx context.Context,
	caseID string,
) (casestore.JoinExecution, error) {
	if executor == nil {
		return casestore.JoinExecution{}, fmt.Errorf("joined-file import executor is not configured")
	}
	if err := ctx.Err(); err != nil {
		return casestore.JoinExecution{}, err
	}
	execution, found, err := executor.dependencies.Store.GetJoinExecution(caseID)
	if err != nil {
		return casestore.JoinExecution{}, fmt.Errorf("read joined-file execution: %w", err)
	}
	if !found {
		return casestore.JoinExecution{}, fmt.Errorf("join for case %q is not prepared", caseID)
	}

	switch execution.State {
	case casestore.JoinPublished:
		return executor.prepareAndSubmit(ctx, caseID, execution)
	case casestore.JoinScanPrepared:
		return executor.resumePrepared(ctx, execution)
	case casestore.JoinScanRequested:
		return executor.follow(ctx, execution)
	case casestore.JoinImported, casestore.JoinImportFailed:
		return execution, nil
	default:
		return execution, fmt.Errorf(
			"join state %q is not ready for Radarr import",
			execution.State,
		)
	}
}

func (executor *Executor) prepareAndSubmit(
	ctx context.Context,
	caseID string,
	execution casestore.JoinExecution,
) (casestore.JoinExecution, error) {
	request, err := executor.scanRequest(caseID, execution)
	if err != nil {
		return execution, err
	}
	preparedAt, err := executor.now()
	if err != nil {
		return execution, err
	}
	execution, prepared, err := executor.dependencies.Store.PrepareJoinScan(
		caseID,
		request,
		preparedAt,
	)
	if err != nil {
		return execution, fmt.Errorf("prepare Radarr joined-file scan: %w", err)
	}
	if !prepared {
		return executor.resume(ctx, execution)
	}

	command, err := executor.dependencies.Radarr.RequestDownloadedMoviesScan(
		ctx,
		radarr.DownloadedMoviesScan{Path: request.Path, DownloadID: request.DownloadID},
	)
	if err != nil {
		confirmed, confirmErr := executor.confirm(ctx, execution)
		if confirmed.State == casestore.JoinImported {
			return confirmed, confirmErr
		}
		return execution, &SubmissionUncertainError{
			CaseID: caseID,
			cause: errors.Join(
				fmt.Errorf("request Radarr joined-file scan: %w", err),
				confirmErr,
			),
		}
	}
	requestedAt, err := executor.now()
	if err != nil {
		return execution, &SubmissionUncertainError{CaseID: caseID, cause: err}
	}
	execution, _, err = executor.dependencies.Store.MarkJoinScanRequested(
		caseID,
		command.ID,
		requestedAt,
	)
	if err != nil {
		return execution, &SubmissionUncertainError{
			CaseID: caseID,
			cause:  fmt.Errorf("record Radarr joined-file scan command: %w", err),
		}
	}
	return executor.follow(ctx, execution)
}

func (executor *Executor) resume(
	ctx context.Context,
	execution casestore.JoinExecution,
) (casestore.JoinExecution, error) {
	switch execution.State {
	case casestore.JoinImported, casestore.JoinImportFailed:
		return execution, nil
	case casestore.JoinScanRequested:
		return executor.follow(ctx, execution)
	case casestore.JoinScanPrepared:
		return executor.resumePrepared(ctx, execution)
	default:
		return execution, fmt.Errorf("unknown joined-file import state %q", execution.State)
	}
}

func (executor *Executor) resumePrepared(
	ctx context.Context,
	execution casestore.JoinExecution,
) (casestore.JoinExecution, error) {
	confirmed, err := executor.confirm(ctx, execution)
	if confirmed.State == casestore.JoinImported {
		return confirmed, err
	}
	return execution, &SubmissionUncertainError{
		CaseID: execution.Authorization.CaseID,
		cause:  err,
	}
}

func (executor *Executor) follow(
	ctx context.Context,
	execution casestore.JoinExecution,
) (casestore.JoinExecution, error) {
	if execution.Scan == nil || execution.Scan.CommandID == nil {
		return execution, fmt.Errorf("requested joined-file scan has no Radarr command ID")
	}
	for {
		confirmed, err := executor.confirm(ctx, execution)
		if err != nil || confirmed.State == casestore.JoinImported {
			return confirmed, err
		}

		command, err := executor.dependencies.Radarr.ReadDownloadedMoviesScanCommand(
			ctx,
			*execution.Scan.CommandID,
		)
		if err != nil {
			return execution, fmt.Errorf("read Radarr joined-file scan command: %w", err)
		}
		disposition, err := radarr.ClassifyImportCommand(command)
		if err != nil {
			return execution, err
		}
		if disposition == radarr.ImportCommandFailed {
			failedAt, nowErr := executor.now()
			if nowErr != nil {
				return execution, nowErr
			}
			execution, _, err = executor.dependencies.Store.MarkJoinImportFailed(
				execution.Authorization.CaseID,
				failedAt,
			)
			if err != nil {
				return execution, fmt.Errorf("record failed Radarr joined-file scan: %w", err)
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
	execution casestore.JoinExecution,
) (casestore.JoinExecution, error) {
	if execution.Scan == nil {
		return execution, fmt.Errorf("joined-file import has no prepared Radarr scan")
	}
	imports, err := executor.dependencies.Radarr.ReadImportedFiles(
		ctx,
		execution.Scan.MovieID,
		execution.Scan.DownloadID,
	)
	if err != nil {
		return execution, fmt.Errorf("read Radarr imported-file history: %w", err)
	}
	imported, found := radarr.FindImportedFile(imports, radarr.ImportedFileMatch{
		MovieID: execution.Scan.MovieID, DownloadID: execution.Scan.DownloadID,
		DroppedPath: execution.Scan.Path, After: execution.Scan.PreparedAt,
	})
	if !found {
		return execution, nil
	}
	confirmedAt, err := executor.now()
	if err != nil {
		return execution, err
	}
	confirmed, _, err := executor.dependencies.Store.MarkJoinImported(
		execution.Authorization.CaseID,
		imported,
		confirmedAt,
	)
	if err != nil {
		return execution, fmt.Errorf("record confirmed Radarr joined-file import: %w", err)
	}
	return confirmed, nil
}

func (executor *Executor) scanRequest(
	caseID string,
	execution casestore.JoinExecution,
) (casestore.JoinScanRequest, error) {
	if execution.Published == nil {
		return casestore.JoinScanRequest{}, fmt.Errorf("published join has no destination")
	}
	record, found, err := executor.dependencies.Store.Get(caseID)
	if err != nil {
		return casestore.JoinScanRequest{}, fmt.Errorf("read joined-file case: %w", err)
	}
	if !found {
		return casestore.JoinScanRequest{}, fmt.Errorf("case %q is not stored", caseID)
	}
	queue := record.Snapshot.Observation.Correlation.Radarr
	if queue.MovieID == nil || *queue.MovieID <= 0 {
		return casestore.JoinScanRequest{}, fmt.Errorf("joined-file case has no Radarr movie ID")
	}
	path, err := executor.dependencies.Paths.ResolvePublishedPath(
		execution.Published.RootID,
		execution.Published.PathComponents,
	)
	if err != nil {
		return casestore.JoinScanRequest{}, fmt.Errorf("resolve published joined file: %w", err)
	}
	return casestore.JoinScanRequest{
		Path: path, MovieID: *queue.MovieID, DownloadID: queue.DownloadID,
	}, nil
}

func (executor *Executor) now() (time.Time, error) {
	now := executor.dependencies.Clock.Now().UTC()
	if now.IsZero() {
		return time.Time{}, fmt.Errorf("joined-file import clock returned a zero time")
	}
	return now, nil
}

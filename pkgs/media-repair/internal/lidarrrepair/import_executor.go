package lidarrrepair

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

type ImportClient interface {
	RequestManualImport(context.Context, lidarr.ManualImportCommand) (servarr.Command, error)
	ReadManualImportCommand(context.Context, int64) (servarr.Command, error)
	ReadImportedTracks(context.Context, int64, string) ([]lidarr.ImportedTrack, error)
}

type ImportStore interface {
	PrepareImport(AuthorizedImport, int64, time.Time) (ImportExecution, bool, error)
	MarkImportRequested(string, int64, time.Time) (ImportExecution, bool, error)
	MarkImported(string, []lidarr.ImportedTrack, time.Time) (ImportExecution, bool, error)
	MarkImportFailed(string, time.Time) (ImportExecution, bool, error)
}

type ImportExecutorDependencies struct {
	Lidarr       ImportClient
	Store        ImportStore
	Clock        servarr.Clock
	Waiter       servarr.Waiter
	PollInterval time.Duration
}

type ImportExecutor struct {
	dependencies ImportExecutorDependencies
}

func NewImportExecutor(dependencies ImportExecutorDependencies) (*ImportExecutor, error) {
	switch {
	case dependencies.Lidarr == nil:
		return nil, fmt.Errorf("Lidarr manual importer is required")
	case dependencies.Store == nil:
		return nil, fmt.Errorf("Lidarr import execution store is required")
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("Lidarr import execution clock is required")
	case dependencies.Waiter == nil:
		return nil, fmt.Errorf("Lidarr import poll waiter is required")
	case dependencies.PollInterval <= 0:
		return nil, fmt.Errorf("Lidarr import poll interval must be positive")
	default:
		return &ImportExecutor{dependencies: dependencies}, nil
	}
}

func (executor *ImportExecutor) Execute(
	ctx context.Context,
	authorized AuthorizedImport,
) (ImportExecution, error) {
	if executor == nil {
		return ImportExecution{}, fmt.Errorf("Lidarr import executor is not configured")
	}
	if err := ctx.Err(); err != nil {
		return ImportExecution{}, err
	}
	if len(authorized.Tracks) == 0 || authorized.AlbumID <= 0 ||
		authorized.Tracks[0].DownloadID == "" {
		return ImportExecution{}, fmt.Errorf("Lidarr import authorization is incomplete")
	}
	history, err := executor.dependencies.Lidarr.ReadImportedTracks(
		ctx,
		authorized.AlbumID,
		"",
	)
	if err != nil {
		return ImportExecution{}, fmt.Errorf("read Lidarr history before manual import: %w", err)
	}
	preparedAt, err := executor.now()
	if err != nil {
		return ImportExecution{}, err
	}
	execution, prepared, err := executor.dependencies.Store.PrepareImport(
		authorized,
		lidarr.HighestImportedTrackHistoryID(history),
		preparedAt,
	)
	if err != nil {
		return ImportExecution{}, fmt.Errorf("prepare Lidarr manual import: %w", err)
	}
	return executor.run(ctx, authorized, execution, prepared)
}

func (executor *ImportExecutor) run(
	ctx context.Context,
	authorized AuthorizedImport,
	execution ImportExecution,
	newlyPrepared bool,
) (ImportExecution, error) {
	flow, err := servarr.NewImportExecution(
		servarr.ImportExecutionDependencies[ImportExecution]{
			Service: "Lidarr", Operation: "missing-track import",
			Clock: executor.dependencies.Clock, Waiter: executor.dependencies.Waiter,
			PollInterval: executor.dependencies.PollInterval, RequireCompletionResult: false,
			CaseID: func(current ImportExecution) string { return current.CaseID },
			State:  lidarrImportState,
			CommandID: func(current ImportExecution) (int64, bool) {
				if current.CommandID == nil {
					return 0, false
				}
				return *current.CommandID, true
			},
			Submit: func(ctx context.Context) (servarr.Command, error) {
				return executor.dependencies.Lidarr.RequestManualImport(
					ctx,
					manualImportCommand(authorized),
				)
			},
			ReadCommand: executor.dependencies.Lidarr.ReadManualImportCommand,
			Confirm:     executor.confirm,
			MarkRequested: func(
				current ImportExecution,
				commandID int64,
				at time.Time,
			) (ImportExecution, error) {
				updated, _, markErr := executor.dependencies.Store.MarkImportRequested(
					current.CaseID,
					commandID,
					at,
				)
				return updated, markErr
			},
			MarkFailed: func(current ImportExecution, at time.Time) (ImportExecution, error) {
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

func lidarrImportState(execution ImportExecution) (servarr.ImportExecutionState, error) {
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
		return 0, fmt.Errorf("unknown Lidarr import execution state %q", execution.State)
	}
}

func manualImportCommand(authorized AuthorizedImport) lidarr.ManualImportCommand {
	files := make([]lidarr.ManualImportCommandFile, len(authorized.Tracks))
	for index, track := range authorized.Tracks {
		files[index] = lidarr.ManualImportCommandFile{
			Path: track.Path, ArtistID: authorized.ArtistID, AlbumID: authorized.AlbumID,
			AlbumReleaseID: authorized.ReleaseID, TrackID: track.TrackID,
			Quality: track.Quality, IndexerFlags: track.IndexerFlags,
			DisableReleaseSwitching: track.DisableReleaseSwitching,
		}
	}
	return lidarr.ManualImportCommand{Files: files}
}

func (executor *ImportExecutor) confirm(
	ctx context.Context,
	execution ImportExecution,
) (ImportExecution, bool, error) {
	history, err := executor.dependencies.Lidarr.ReadImportedTracks(
		ctx,
		execution.AlbumID,
		"",
	)
	if err != nil {
		return execution, false, fmt.Errorf("read Lidarr imported-track history: %w", err)
	}
	confirmations := make([]lidarr.ImportedTrack, 0, len(execution.Tracks))
	for _, track := range execution.Tracks {
		confirmed, found := lidarr.FindImportedTrack(history, lidarr.ImportedTrackMatch{
			TrackID: track.TrackID, DroppedPath: track.Path,
			AfterHistoryID: execution.HistoryIDBefore, NotBefore: execution.PreparedAt,
		})
		if !found {
			return execution, false, nil
		}
		confirmations = append(confirmations, confirmed)
	}
	sort.Slice(confirmations, func(left, right int) bool {
		return confirmations[left].TrackID < confirmations[right].TrackID
	})
	confirmedAt, err := executor.now()
	if err != nil {
		return execution, false, err
	}
	confirmed, _, err := executor.dependencies.Store.MarkImported(
		execution.CaseID,
		confirmations,
		confirmedAt,
	)
	if err != nil {
		return execution, false, fmt.Errorf("record confirmed Lidarr manual import: %w", err)
	}
	return confirmed, true, nil
}

func (executor *ImportExecutor) now() (time.Time, error) {
	now := executor.dependencies.Clock.Now().UTC()
	if now.IsZero() {
		return time.Time{}, fmt.Errorf("clock returned a zero time")
	}
	return now, nil
}

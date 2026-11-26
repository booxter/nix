package repairradarr

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/mediaoperation"
	"github.com/booxter/nix-config/media-repair/internal/radarr"
	"github.com/booxter/nix-config/media-repair/internal/repair"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

type Client interface {
	ReadQueue(context.Context) ([]controller.RadarrQueueRecord, error)
	ReadMovie(context.Context, int64) (controller.RadarrMovie, error)
	RecoverMovieID(context.Context, string) (int64, bool, error)
	FinalizeQueue(context.Context, int64, bool) error
	RequestManualImport(context.Context, controller.RadarrManualImportCommand) (servarr.Command, error)
	ReadManualImportCommand(context.Context, int64) (servarr.Command, error)
	ReadImportedFiles(context.Context, int64, string) ([]controller.RadarrImportedFile, error)
}

type Media interface {
	Transform(context.Context, mediaoperation.Transform) (mediaoperation.Output, error)
}

type Evidence struct {
	Case     contracts.RepairCaseV3
	Snapshot casebuilder.LocalSnapshot
}

func (evidence Evidence) Assembly() casebuilder.Assembly {
	return casebuilder.Assembly{Request: evidence.Case, LocalSnapshot: evidence.Snapshot}
}

type Adapter struct {
	Inspector     *Inspector
	Client        Client
	Media         Media
	Planner       Planner
	Stabilization time.Duration
	Now           func() time.Time
}

func (adapter *Adapter) ImportSteps() repair.ImportFlow {
	return repair.ImportSteps[authorizedRepair]{
		Authorize:     adapter.authorize,
		PrepareImport: adapter.prepareImport,
	}
}

func (adapter *Adapter) prepareImport(
	ctx context.Context,
	attempt jobs.Attempt,
	authorized authorizedRepair,
) (repair.PreparedImport, error) {
	command, err := adapter.importCommand(ctx, attempt, authorized)
	if err != nil {
		return repair.PreparedImport{}, err
	}

	history, err := adapter.Client.ReadImportedFiles(ctx, command.File.MovieID, command.File.DownloadID)
	if err != nil {
		return repair.PreparedImport{}, err
	}

	request, err := json.Marshal(command)
	return repair.PreparedImport{
		OutputPath:      command.File.Path,
		Request:         request,
		HistoryIDBefore: radarr.HighestImportedFileHistoryID(history),
	}, err
}

func (adapter *Adapter) importCommand(
	ctx context.Context,
	attempt jobs.Attempt,
	repair authorizedRepair,
) (controller.RadarrManualImportCommand, error) {
	fresh, authorized := repair.source, repair.operation
	if authorized.ManualImport != nil {
		return *authorized.ManualImport, nil
	}

	paths := make(map[controller.FileID]string)
	for _, path := range fresh.LocalSnapshot.Observation.Inventory.Paths {
		paths[path.FileID] = path.AbsolutePath
	}

	output, err := adapter.Media.Transform(ctx, mediaoperation.Transform{
		JobID: attempt.JobID, Attempt: attempt.Number, Paths: paths,
		Join: authorized.Join, Bluray: authorized.Remux, DVD: authorized.DVD,
	})
	if err != nil {
		return controller.RadarrManualImportCommand{}, err
	}

	queue := fresh.LocalSnapshot.Observation.Correlation.Radarr
	if queue.MovieID == nil {
		return controller.RadarrManualImportCommand{}, fmt.Errorf("queue item has no movie identity")
	}
	command, complete := controller.BuildRadarrPublishedFileImport(
		output.Path, *queue.MovieID, queue.DownloadID, fresh.LocalSnapshot.Observation.History,
	)
	if !complete {
		return controller.RadarrManualImportCommand{}, fmt.Errorf("movie has no matching grab metadata for import")
	}

	return command, nil
}

func (adapter *Adapter) Submit(ctx context.Context, request json.RawMessage) (int64, error) {
	var command controller.RadarrManualImportCommand
	if err := json.Unmarshal(request, &command); err != nil {
		return 0, err
	}

	result, err := adapter.Client.RequestManualImport(ctx, command)
	return result.ID, err
}

func (adapter *Adapter) ConfirmationSteps() repair.ConfirmationSteps {
	return repair.ConfirmationSteps{
		FindReceipt:             adapter.findReceipt,
		ReadCommandStatus:       adapter.Client.ReadManualImportCommand,
		RequireCompletionResult: true,
	}
}

// Match the file sent to Radarr against history recorded after this attempt began.
func (adapter *Adapter) findReceipt(ctx context.Context, attempt jobs.Attempt) (json.RawMessage, error) {
	var request controller.RadarrManualImportCommand
	if err := json.Unmarshal(attempt.ImportRequest, &request); err != nil {
		return nil, err
	}

	history, err := adapter.Client.ReadImportedFiles(ctx, request.File.MovieID, request.File.DownloadID)
	if err != nil {
		return nil, err
	}

	imported, found := radarr.FindImportedFile(history, radarr.ImportedFileMatch{
		MovieID: request.File.MovieID, DownloadID: request.File.DownloadID,
		DroppedPath: request.File.Path, AfterHistoryID: attempt.HistoryIDBefore,
	})
	if !found {
		return nil, nil
	}
	return json.Marshal(imported)
}

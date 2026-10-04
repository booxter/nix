package repairradarr

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/executioncheck"
	"github.com/booxter/nix-config/media-repair/internal/inspection"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/mediaoperation"
	"github.com/booxter/nix-config/media-repair/internal/radarr"
	"github.com/booxter/nix-config/media-repair/internal/repair"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

type Inspector interface {
	Inspect(context.Context, inspection.Selection) (casebuilder.Assembly, error)
	InspectAll(context.Context) (inspection.Result, error)
}

type Client interface {
	ReadQueue(context.Context) ([]controller.RadarrQueueRecord, error)
	ReadMovie(context.Context, int64) (controller.RadarrMovie, error)
	RecoverMovieID(context.Context, string) (int64, bool, error)
	FinalizeQueue(context.Context, int64) error
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
	Inspector     Inspector
	Client        Client
	Media         Media
	Planner       Planner
	Stabilization time.Duration
	Now           func() time.Time
}

func (adapter *Adapter) Repair(ctx context.Context, job jobs.Job, attempt jobs.Attempt) (repair.PreparedImport, error) {
	fresh, authorized, err := adapter.authorize(ctx, job, attempt.Plan)
	if err != nil {
		return repair.PreparedImport{}, err
	}

	command, err := adapter.importCommand(ctx, job, attempt, fresh, authorized)
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

func (adapter *Adapter) authorize(
	ctx context.Context,
	job jobs.Job,
	plan json.RawMessage,
) (casebuilder.Assembly, executioncheck.Authorization, error) {
	var evidence Evidence
	if err := json.Unmarshal(job.Evidence, &evidence); err != nil {
		return casebuilder.Assembly{}, executioncheck.Authorization{}, err
	}

	decision, err := contracts.DecodeDecision(plan)
	if err != nil {
		return casebuilder.Assembly{}, executioncheck.Authorization{}, err
	}

	entries, err := adapter.Client.ReadQueue(ctx)
	if err != nil {
		return casebuilder.Assembly{}, executioncheck.Authorization{}, err
	}
	keys := make([]jobs.QueueKey, len(entries))
	for index, entry := range entries {
		keys[index] = jobs.QueueKey{QueueID: entry.ID, DownloadID: entry.DownloadID}
	}
	index, err := jobs.MatchQueue(job.QueueKey(), keys)
	if err != nil {
		return casebuilder.Assembly{}, executioncheck.Authorization{}, &repair.BlockedError{Reason: err.Error()}
	}
	if index < 0 {
		return casebuilder.Assembly{}, executioncheck.Authorization{}, &repair.BlockedError{Reason: "download is no longer queued"}
	}
	fresh, err := adapter.Inspector.Inspect(ctx, inspection.Selection{QueueID: entries[index].ID})
	if err != nil {
		return fresh, executioncheck.Authorization{}, err
	}

	// Planning can be slow; authorize against fresh source and queue evidence.
	queue := fresh.LocalSnapshot.Observation.Correlation.Radarr
	if queue.DownloadID != job.DownloadID || !casebuilder.SameCaseState(evidence.Assembly(), fresh) {
		return fresh, executioncheck.Authorization{}, &repair.BlockedError{Reason: "source or queue identity changed; collect a new plan"}
	}
	if queue.TrackedDownloadState == "importPending" && adapter.Now().Sub(job.StableSince) < adapter.Stabilization {
		return fresh, executioncheck.Authorization{}, &repair.BlockedError{Reason: "source is still stabilizing"}
	}

	policy := decisionpolicy.RuntimePolicy{MaximumDifferenceMS: job.RuntimeToleranceMS}
	authorized, reason, _, accepted := executioncheck.Authorize(fresh, decision, policy)
	if !accepted {
		return fresh, authorized, &repair.BlockedError{Reason: "decision rejected: " + reason}
	}
	if reason, unsafe := executioncheck.ReplacementRejection(fresh, authorized); unsafe {
		return fresh, authorized, &repair.BlockedError{Reason: string(reason)}
	}

	return fresh, authorized, nil
}

func (adapter *Adapter) importCommand(
	ctx context.Context,
	job jobs.Job,
	attempt jobs.Attempt,
	fresh casebuilder.Assembly,
	authorized executioncheck.Authorization,
) (controller.RadarrManualImportCommand, error) {
	if authorized.ManualImport != nil {
		return controller.RadarrManualImportCommand{
			ImportMode: authorized.ManualImport.ImportMode,
			File:       authorized.ManualImport.File,
		}, nil
	}

	paths := make(map[controller.FileID]string)
	for _, path := range fresh.LocalSnapshot.Observation.Inventory.Paths {
		paths[path.FileID] = path.AbsolutePath
	}

	output, err := adapter.Media.Transform(ctx, mediaoperation.Transform{
		JobID: job.ID, Attempt: attempt.Number, Paths: paths,
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

func (adapter *Adapter) CheckImport(ctx context.Context, attempt jobs.Attempt) (repair.ImportStatus, error) {
	var request controller.RadarrManualImportCommand
	if err := json.Unmarshal(attempt.ImportRequest, &request); err != nil {
		return repair.ImportStatus{}, err
	}

	history, err := adapter.Client.ReadImportedFiles(ctx, request.File.MovieID, request.File.DownloadID)
	if err != nil {
		return repair.ImportStatus{}, err
	}

	imported, found := radarr.FindImportedFile(history, radarr.ImportedFileMatch{
		MovieID: request.File.MovieID, DownloadID: request.File.DownloadID,
		DroppedPath: request.File.Path, AfterHistoryID: attempt.HistoryIDBefore,
	})
	if found {
		receipt, err := json.Marshal(imported)
		return repair.ImportStatus{Receipt: receipt}, err
	}

	if attempt.CommandID == 0 {
		return repair.ImportStatus{}, nil
	}

	command, err := adapter.Client.ReadManualImportCommand(ctx, attempt.CommandID)
	if err != nil {
		return repair.ImportStatus{}, err
	}

	return repair.CommandStatus(command, true)
}

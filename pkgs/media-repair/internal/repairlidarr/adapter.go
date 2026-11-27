package repairlidarr

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	"github.com/booxter/nix-config/media-repair/internal/repair"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

type Client interface {
	lidarrrepair.Lidarr
	lidarrrepair.ImportClient
	FinalizeQueue(context.Context, int64, bool) error
}

type Inspector interface {
	Inspect(context.Context, lidarr.QueueRecord, *lidarrrepair.Record) lidarrrepair.CollectionResult
}

type Adapter struct {
	Client    Client
	Inspector Inspector
	Planner   lidarrrepair.Planner
}

func (adapter *Adapter) ImportSteps() repair.ImportFlow {
	return repair.ImportSteps[lidarrrepair.AuthorizedImport]{
		Authorize:     adapter.authorize,
		PrepareImport: adapter.prepareImport,
	}
}

// Recheck the saved track selections against the files and library state
// Lidarr sees now. Only matching tracks may go into the import request.
func (adapter *Adapter) authorize(
	ctx context.Context,
	job jobs.Job,
	plan json.RawMessage,
) (lidarrrepair.AuthorizedImport, error) {
	var planned lidarrrepair.Record
	if err := json.Unmarshal(job.Evidence, &planned); err != nil {
		return lidarrrepair.AuthorizedImport{}, err
	}
	planned.Decision = plan

	queue, err := adapter.findQueue(ctx, job.QueueKey())
	if err != nil {
		return lidarrrepair.AuthorizedImport{}, err
	}

	result := adapter.Inspector.Inspect(ctx, queue, &planned)
	if result.Err != nil {
		return lidarrrepair.AuthorizedImport{}, result.Err
	}
	if err := repair.CheckEligibility(result.Findings, jobs.OutcomeQueueNotReady); err != nil {
		return lidarrrepair.AuthorizedImport{}, err
	}

	authorized, accepted, err := lidarrrepair.AuthorizeImport(planned, *result.Case)
	if err != nil {
		blocked := &repair.BlockedError{Reason: err.Error()}
		var changed *lidarrrepair.EvidenceChangedError
		if errors.As(err, &changed) {
			blocked.Code = jobs.OutcomeEvidenceChanged
		}
		return lidarrrepair.AuthorizedImport{}, blocked
	}
	if !accepted {
		return lidarrrepair.AuthorizedImport{}, &repair.BlockedError{Reason: "no missing-track import authorized"}
	}
	return authorized, nil
}

func (adapter *Adapter) prepareImport(
	ctx context.Context,
	_ jobs.Attempt,
	authorized lidarrrepair.AuthorizedImport,
) (repair.PreparedImport, error) {
	history, err := adapter.Client.ReadImportedTracks(ctx, authorized.AlbumID, "")
	if err != nil {
		return repair.PreparedImport{}, err
	}

	request, err := json.Marshal(importCommand(authorized))
	return repair.PreparedImport{
		OutputPath:      authorized.WorkspaceRoot,
		Request:         request,
		HistoryIDBefore: servarr.HighestHistoryID(history),
	}, err
}

func (adapter *Adapter) findQueue(ctx context.Context, key jobs.QueueKey) (lidarr.QueueRecord, error) {
	return repair.ReadQueueEntry(ctx, key, adapter.Client.ReadQueue, func(entry lidarr.QueueRecord) jobs.QueueKey {
		return jobs.QueueKey{QueueID: entry.ID, DownloadID: entry.DownloadID}
	})
}

func importCommand(authorized lidarrrepair.AuthorizedImport) lidarr.ManualImportCommand {
	files := make([]lidarr.ManualImportCommandFile, len(authorized.Tracks))
	for index, track := range authorized.Tracks {
		files[index] = lidarr.ManualImportCommandFile{
			Path:                    track.Path,
			ArtistID:                authorized.ArtistID,
			AlbumID:                 authorized.AlbumID,
			AlbumReleaseID:          authorized.ReleaseID,
			TrackID:                 track.TrackID,
			Quality:                 track.Quality,
			IndexerFlags:            track.IndexerFlags,
			DisableReleaseSwitching: track.DisableReleaseSwitching,
		}
	}

	return lidarr.ManualImportCommand{Files: files}
}

func (adapter *Adapter) Submit(ctx context.Context, data json.RawMessage) (int64, error) {
	var request lidarr.ManualImportCommand
	if err := json.Unmarshal(data, &request); err != nil {
		return 0, err
	}

	command, err := adapter.Client.RequestManualImport(ctx, request)
	return command.ID, err
}

func (adapter *Adapter) ConfirmationSteps() repair.ConfirmationSteps {
	return repair.ConfirmationSteps{
		FindImportedFiles: adapter.findImportedFiles,
		ReadCommandStatus: adapter.Client.ReadManualImportCommand,
	}
}

// An album receipt is complete only when history includes every selected track.
func (adapter *Adapter) findImportedFiles(ctx context.Context, attempt jobs.Attempt) ([]servarr.ImportedFile, error) {
	var request lidarr.ManualImportCommand
	if err := json.Unmarshal(attempt.ImportRequest, &request); err != nil {
		return nil, err
	}
	if len(request.Files) == 0 {
		return nil, fmt.Errorf("stored import has no selected tracks")
	}

	history, err := adapter.Client.ReadImportedTracks(ctx, request.Files[0].AlbumID, "")
	if err != nil {
		return nil, err
	}

	confirmed := make([]servarr.ImportedFile, 0, len(request.Files))
	for _, file := range request.Files {
		imported, found := lidarr.FindImportedTrack(history, lidarr.ImportedTrackMatch{
			TrackID:        file.TrackID,
			DroppedPath:    file.Path,
			AfterHistoryID: attempt.HistoryIDBefore,
			NotBefore:      attempt.ImportStartedAt,
		})
		if !found {
			return nil, nil
		}
		confirmed = append(confirmed, imported)
	}
	return confirmed, nil
}

package repairlidarr

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	"github.com/booxter/nix-config/media-repair/internal/repair"
)

type Client interface {
	lidarrrepair.Lidarr
	lidarrrepair.ImportClient
	FinalizeQueue(context.Context, int64) error
}

type Inspector interface {
	Inspect(context.Context, lidarr.QueueRecord, *lidarrrepair.Record) (lidarrrepair.Evidence, error)
}

type Adapter struct {
	Client    Client
	Inspector Inspector
	Planner   lidarrrepair.Planner
}

func (adapter *Adapter) Repair(ctx context.Context, job jobs.Job, attempt jobs.Attempt) (repair.PreparedImport, error) {
	var planned lidarrrepair.Record
	if err := json.Unmarshal(job.Evidence, &planned); err != nil {
		return repair.PreparedImport{}, err
	}
	planned.Decision = attempt.Plan

	queue, err := adapter.findQueue(ctx, job)
	if err != nil {
		return repair.PreparedImport{}, err
	}

	current, err := adapter.Inspector.Inspect(ctx, queue, &planned)
	if err != nil {
		return repair.PreparedImport{}, err
	}
	authorized, accepted, err := lidarrrepair.AuthorizeImport(planned, current)
	if err != nil {
		return repair.PreparedImport{}, &repair.BlockedError{Reason: err.Error()}
	}
	if !accepted {
		return repair.PreparedImport{}, &repair.BlockedError{Reason: "no missing-track import authorized"}
	}

	history, err := adapter.Client.ReadImportedTracks(ctx, authorized.AlbumID, "")
	if err != nil {
		return repair.PreparedImport{}, err
	}

	request, err := json.Marshal(importCommand(authorized))
	return repair.PreparedImport{
		OutputPath:      current.WorkspaceRoot,
		Request:         request,
		HistoryIDBefore: lidarr.HighestImportedTrackHistoryID(history),
	}, err
}

func (adapter *Adapter) findQueue(ctx context.Context, job jobs.Job) (lidarr.QueueRecord, error) {
	queue, err := adapter.Client.ReadQueue(ctx)
	if err != nil {
		return lidarr.QueueRecord{}, err
	}

	keys := make([]jobs.QueueKey, len(queue))
	for index, entry := range queue {
		keys[index] = jobs.QueueKey{QueueID: entry.ID, DownloadID: entry.DownloadID}
	}
	index, err := jobs.MatchQueue(job.QueueKey(), keys)
	if err != nil {
		return lidarr.QueueRecord{}, &repair.BlockedError{Reason: err.Error()}
	}
	if index >= 0 {
		return queue[index], nil
	}

	return lidarr.QueueRecord{}, &repair.BlockedError{Reason: "queue item disappeared or changed download identity"}
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

func (adapter *Adapter) CheckImport(ctx context.Context, attempt jobs.Attempt) (repair.ImportStatus, error) {
	var request lidarr.ManualImportCommand
	if err := json.Unmarshal(attempt.ImportRequest, &request); err != nil {
		return repair.ImportStatus{}, err
	}
	if len(request.Files) == 0 {
		return repair.ImportStatus{}, fmt.Errorf("stored import has no selected tracks")
	}

	history, err := adapter.Client.ReadImportedTracks(ctx, request.Files[0].AlbumID, "")
	if err != nil {
		return repair.ImportStatus{}, err
	}

	// A completed Lidarr command is not proof that every selected track made
	// it into the library. Match each file against history after our request.
	confirmed := make([]lidarr.ImportedTrack, 0, len(request.Files))
	for _, file := range request.Files {
		imported, found := lidarr.FindImportedTrack(history, lidarr.ImportedTrackMatch{
			TrackID:        file.TrackID,
			DroppedPath:    file.Path,
			AfterHistoryID: attempt.HistoryIDBefore,
			NotBefore:      attempt.ImportStartedAt,
		})
		if found {
			confirmed = append(confirmed, imported)
		}
	}
	if len(confirmed) == len(request.Files) {
		receipt, err := json.Marshal(confirmed)
		return repair.ImportStatus{Receipt: receipt}, err
	}

	if attempt.CommandID == 0 {
		return repair.ImportStatus{}, nil
	}
	command, err := adapter.Client.ReadManualImportCommand(ctx, attempt.CommandID)
	if err != nil {
		return repair.ImportStatus{}, err
	}

	return repair.CommandStatus(command, false)
}

package lidarr

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/internal/servarr"
	"golift.io/starr"
	starrLidarr "golift.io/starr/lidarr"
)

const manualImportCommandName = "ManualImport"

type ManualImportCommandFile struct {
	Path                    string
	ArtistID                int64
	AlbumID                 int64
	AlbumReleaseID          int64
	TrackID                 int64
	Quality                 *starr.Quality
	IndexerFlags            int
	DownloadID              string
	DisableReleaseSwitching bool
}

type ManualImportCommand struct {
	Files []ManualImportCommandFile
}

func (command ManualImportCommand) validate() error {
	if len(command.Files) == 0 {
		return fmt.Errorf("Lidarr manual-import command has no files")
	}
	paths := make(map[string]struct{}, len(command.Files))
	tracks := make(map[int64]struct{}, len(command.Files))
	for index, file := range command.Files {
		if file.Path == "" || !filepath.IsAbs(file.Path) || filepath.Clean(file.Path) != file.Path ||
			strings.ContainsRune(file.Path, '\x00') || file.ArtistID <= 0 || file.AlbumID <= 0 ||
			file.AlbumReleaseID <= 0 || file.TrackID <= 0 || file.Quality == nil ||
			strings.TrimSpace(file.DownloadID) == "" || file.DownloadID != strings.TrimSpace(file.DownloadID) ||
			strings.ContainsRune(file.DownloadID, '\x00') {
			return fmt.Errorf("Lidarr manual-import file %d is incomplete", index)
		}
		if _, duplicate := paths[file.Path]; duplicate {
			return fmt.Errorf("Lidarr manual-import path %q is duplicated", file.Path)
		}
		if _, duplicate := tracks[file.TrackID]; duplicate {
			return fmt.Errorf("Lidarr manual-import track %d is duplicated", file.TrackID)
		}
		paths[file.Path] = struct{}{}
		tracks[file.TrackID] = struct{}{}
	}
	return nil
}

func (client *Client) RequestManualImport(
	ctx context.Context,
	command ManualImportCommand,
) (servarr.Command, error) {
	if err := command.validate(); err != nil {
		return servarr.Command{}, err
	}
	files := make([]*starrLidarr.ManualImportFile, len(command.Files))
	for index, file := range command.Files {
		files[index] = &starrLidarr.ManualImportFile{
			Path: file.Path, ArtistID: file.ArtistID, AlbumID: file.AlbumID,
			AlbumReleaseID: file.AlbumReleaseID, TrackIDs: []int64{file.TrackID},
			Quality: cloneQuality(file.Quality), IndexerFlags: file.IndexerFlags,
			DownloadID: file.DownloadID, DisableReleaseSwitching: file.DisableReleaseSwitching,
		}
	}
	response, err := client.api.SendManualImportCommandContext(
		ctx,
		&starrLidarr.ManualImportCommandRequest{
			Name: manualImportCommandName, Files: files, ImportMode: "auto",
			ReplaceExistingFiles: false,
		},
	)
	if err != nil {
		return servarr.Command{}, servarr.NormalizeRequestError(
			"Lidarr",
			"request Lidarr manual import",
			err,
		)
	}
	return mapCommand(response, 0)
}

func (client *Client) ReadManualImportCommand(
	ctx context.Context,
	commandID int64,
) (servarr.Command, error) {
	if commandID <= 0 {
		return servarr.Command{}, fmt.Errorf("Lidarr command ID must be positive")
	}
	response, err := client.api.GetCommandStatusContext(ctx, commandID)
	if err != nil {
		return servarr.Command{}, servarr.NormalizeRequestError(
			"Lidarr",
			"read Lidarr command",
			err,
		)
	}
	return mapCommand(response, commandID)
}

func mapCommand(response *starrLidarr.CommandResponse, expectedID int64) (servarr.Command, error) {
	if response == nil || response.ID <= 0 {
		return servarr.Command{}, fmt.Errorf("Lidarr command response has an invalid ID")
	}
	if expectedID > 0 && response.ID != expectedID {
		return servarr.Command{}, fmt.Errorf(
			"Lidarr returned command ID %d for requested ID %d",
			response.ID,
			expectedID,
		)
	}
	name := response.Name
	if name == "" {
		name = response.CommandName
	}
	if name != manualImportCommandName {
		return servarr.Command{}, fmt.Errorf(
			"Lidarr returned command %q instead of %q",
			name,
			manualImportCommandName,
		)
	}
	if response.Status == "" {
		return servarr.Command{}, fmt.Errorf("Lidarr command response has no status")
	}
	return servarr.Command{
		ID: response.ID, Name: name, Message: response.Message,
		Status: servarr.CommandStatus(response.Status),
	}, nil
}

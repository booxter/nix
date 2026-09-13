package radarr

import (
	"context"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	starrRadarr "golift.io/starr/radarr"
)

const importedHistoryEvent = "downloadFolderImported"

var _ controller.RadarrImportedFileReader = (*Client)(nil)

func (client *Client) ReadImportedFiles(
	ctx context.Context,
	movieID int64,
	downloadID string,
) ([]controller.RadarrImportedFile, error) {
	records, err := client.readHistoryRecords(ctx, movieID, downloadID)
	if err != nil {
		return nil, err
	}
	imports := make([]controller.RadarrImportedFile, 0)
	for index, record := range records {
		if record.EventType != importedHistoryEvent {
			continue
		}
		imported, err := mapImportedFile(record)
		if err != nil {
			return nil, fmt.Errorf("Radarr imported-file history record %d: %w", index, err)
		}
		imports = append(imports, imported)
	}
	return imports, nil
}

func mapImportedFile(record *starrRadarr.HistoryRecord) (controller.RadarrImportedFile, error) {
	movieFileID, err := strconv.ParseInt(record.Data.FileID, 10, 64)
	if err != nil || movieFileID <= 0 {
		return controller.RadarrImportedFile{}, fmt.Errorf(
			"movie file ID %q is invalid",
			record.Data.FileID,
		)
	}
	if !validHistoryPath(record.Data.DroppedPath) {
		return controller.RadarrImportedFile{}, fmt.Errorf("dropped path is invalid")
	}
	if !validHistoryPath(record.Data.ImportedPath) {
		return controller.RadarrImportedFile{}, fmt.Errorf("imported path is invalid")
	}
	return controller.RadarrImportedFile{
		HistoryID: record.ID, MovieFileID: movieFileID, MovieID: record.MovieID,
		DownloadID: record.DownloadID, OccurredAt: record.Date.UTC(),
		DroppedPath: record.Data.DroppedPath, ImportedPath: record.Data.ImportedPath,
	}, nil
}

func validHistoryPath(path string) bool {
	return path != "" && !strings.ContainsRune(path, '\x00') &&
		filepath.IsAbs(path) && filepath.Clean(path) == path && filepath.Dir(path) != path
}

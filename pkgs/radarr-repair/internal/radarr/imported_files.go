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

type ImportedFileMatch struct {
	MovieID        int64
	DownloadID     string
	DroppedPath    string
	AfterHistoryID int64
}

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

// HighestImportedFileHistoryID captures the history boundary before a request.
func HighestImportedFileHistoryID(imports []controller.RadarrImportedFile) int64 {
	var highest int64
	for _, imported := range imports {
		if imported.HistoryID > highest {
			highest = imported.HistoryID
		}
	}
	return highest
}

// FindImportedFile ignores exact matches that existed before the request.
func FindImportedFile(
	imports []controller.RadarrImportedFile,
	match ImportedFileMatch,
) (controller.RadarrImportedFile, bool) {
	var selected controller.RadarrImportedFile
	found := false
	for _, imported := range imports {
		if imported.MovieID != match.MovieID || imported.DownloadID != match.DownloadID ||
			imported.DroppedPath != match.DroppedPath ||
			imported.HistoryID <= match.AfterHistoryID {
			continue
		}
		if !found || imported.HistoryID < selected.HistoryID {
			selected = imported
			found = true
		}
	}
	return selected, found
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

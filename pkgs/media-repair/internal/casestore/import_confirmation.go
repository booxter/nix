package casestore

import (
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

type RadarrImportConfirmation struct {
	HistoryID    int64     `json:"history_id"`
	MovieFileID  int64     `json:"movie_file_id"`
	MovieID      int64     `json:"movie_id"`
	DownloadID   string    `json:"download_id"`
	OccurredAt   time.Time `json:"occurred_at"`
	DroppedPath  string    `json:"dropped_path"`
	ImportedPath string    `json:"imported_path"`
}

func radarrImportConfirmation(
	imported controller.RadarrImportedFile,
) RadarrImportConfirmation {
	return RadarrImportConfirmation{
		HistoryID: imported.HistoryID, MovieFileID: imported.MovieFileID,
		MovieID: imported.MovieID, DownloadID: imported.DownloadID,
		OccurredAt: imported.OccurredAt.UTC(), DroppedPath: imported.DroppedPath,
		ImportedPath: imported.ImportedPath,
	}
}

func validateRadarrImportConfirmation(confirmation RadarrImportConfirmation) error {
	if confirmation.HistoryID <= 0 || confirmation.MovieFileID <= 0 || confirmation.MovieID <= 0 {
		return fmt.Errorf("Radarr import confirmation IDs must be positive")
	}
	if confirmation.DownloadID == "" ||
		strings.TrimSpace(confirmation.DownloadID) != confirmation.DownloadID ||
		strings.ContainsRune(confirmation.DownloadID, '\x00') {
		return fmt.Errorf("Radarr import confirmation download ID is invalid")
	}
	if confirmation.OccurredAt.IsZero() {
		return fmt.Errorf("Radarr import confirmation time is missing")
	}
	if !validExecutionPath(confirmation.DroppedPath) ||
		!validExecutionPath(confirmation.ImportedPath) {
		return fmt.Errorf("Radarr import confirmation paths are invalid")
	}
	return nil
}

func validExecutionPath(path string) bool {
	return path != "" && !strings.ContainsRune(path, '\x00') &&
		filepath.IsAbs(path) && filepath.Clean(path) == path && filepath.Dir(path) != path
}

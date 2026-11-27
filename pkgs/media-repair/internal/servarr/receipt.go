package servarr

import (
	"bytes"
	"encoding/json"
	"fmt"
	"time"
)

type ImportReceipt struct {
	Files []ImportedFile `json:"files"`
}

// Each file is one confirmed import from service history. Its library paths
// belong in the receipt and must stay out of the case sent to the planner.
type ImportedFile struct {
	HistoryID    int64     `json:"historyId"`
	DownloadID   string    `json:"downloadId"`
	DroppedPath  string    `json:"droppedPath"`
	ImportedPath string    `json:"importedPath"`
	OccurredAt   time.Time `json:"occurredAt"`

	MovieID     int64 `json:"movieId,omitempty"`
	MovieFileID int64 `json:"movieFileId,omitempty"`
	ArtistID    int64 `json:"artistId,omitempty"`
	AlbumID     int64 `json:"albumId,omitempty"`
	TrackID     int64 `json:"trackId,omitempty"`
}

// Record the last history ID before submission so older imports cannot confirm this attempt.
func HighestHistoryID(files []ImportedFile) int64 {
	var highest int64
	for _, file := range files {
		highest = max(highest, file.HistoryID)
	}
	return highest
}

// Older jobs stored a bare movie object or a list of tracks. Read both
// formats here so saved receipts look the same as new ones after a restart.
func (r *ImportReceipt) UnmarshalJSON(data []byte) error {
	if bytes.HasPrefix(bytes.TrimSpace(data), []byte("[")) {
		files, err := readLegacyTracks(data)
		if err != nil {
			return err
		}
		r.Files = files
		return nil
	}

	var saved struct {
		Files        []ImportedFile `json:"files"`
		ImportedFile                // Old movie keys differ only in capitalization.
	}
	if err := json.Unmarshal(data, &saved); err != nil {
		return err
	}
	switch {
	case saved.Files != nil:
		r.Files = saved.Files
	case saved.MovieID != 0:
		r.Files = []ImportedFile{saved.ImportedFile}
	default:
		return fmt.Errorf("import receipt has no files")
	}
	return nil
}

func readLegacyTracks(data []byte) ([]ImportedFile, error) {
	var tracks []struct {
		HistoryID    int64     `json:"history_id"`
		DownloadID   string    `json:"download_id"`
		DroppedPath  string    `json:"dropped_path"`
		ImportedPath string    `json:"imported_path"`
		OccurredAt   time.Time `json:"occurred_at"`
		ArtistID     int64     `json:"artist_id"`
		AlbumID      int64     `json:"album_id"`
		TrackID      int64     `json:"track_id"`
	}
	if err := json.Unmarshal(data, &tracks); err != nil {
		return nil, err
	}
	files := make([]ImportedFile, len(tracks))
	for i, track := range tracks {
		files[i] = ImportedFile{
			HistoryID: track.HistoryID, DownloadID: track.DownloadID, OccurredAt: track.OccurredAt,
			DroppedPath: track.DroppedPath, ImportedPath: track.ImportedPath,
			ArtistID: track.ArtistID, AlbumID: track.AlbumID, TrackID: track.TrackID,
		}
	}
	return files, nil
}

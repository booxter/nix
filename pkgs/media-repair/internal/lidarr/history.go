package lidarr

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/servarr"
	"golift.io/starr"
	starrLidarr "golift.io/starr/lidarr"
)

const (
	historyPageSize        = 250
	maximumHistoryPages    = 40
	maximumHistoryRecords  = historyPageSize * maximumHistoryPages
	trackFileImportedEvent = "trackFileImported"
)

type ImportedTrack struct {
	HistoryID    int64     `json:"history_id"`
	AlbumID      int64     `json:"album_id"`
	ArtistID     int64     `json:"artist_id"`
	TrackID      int64     `json:"track_id"`
	DownloadID   string    `json:"download_id"`
	DroppedPath  string    `json:"dropped_path"`
	ImportedPath string    `json:"imported_path"`
	OccurredAt   time.Time `json:"occurred_at"`
}

func (client *Client) ReadImportedTracks(
	ctx context.Context,
	albumID int64,
	downloadID string,
) ([]ImportedTrack, error) {
	if albumID <= 0 || downloadID != strings.TrimSpace(downloadID) ||
		strings.ContainsRune(downloadID, '\x00') {
		return nil, fmt.Errorf("Lidarr imported-track history query is invalid")
	}
	var imports []ImportedTrack
	seen := make(map[int64]struct{})
	expectedTotal := -1
	for page := 1; page <= maximumHistoryPages; page++ {
		request := &starr.PageReq{
			Page: page, PageSize: historyPageSize, SortKey: "date", SortDir: starr.SortDescend,
		}
		request.Set("albumId", strconv.FormatInt(albumID, 10))
		if downloadID != "" {
			request.Set("downloadId", downloadID)
		}
		request.Set("eventType", strconv.Itoa(int(starrLidarr.FilterTrackFileImported)))
		response, err := client.api.GetHistoryPageContext(ctx, request)
		if err != nil {
			return nil, servarr.NormalizeRequestError(
				"Lidarr",
				fmt.Sprintf("read Lidarr history page %d", page),
				err,
			)
		}
		if response == nil || response.Page != page || response.PageSize <= 0 ||
			response.PageSize > historyPageSize || len(response.Records) > response.PageSize ||
			response.TotalRecords < 0 || response.TotalRecords > maximumHistoryRecords {
			return nil, fmt.Errorf("Lidarr history page %d is invalid", page)
		}
		if expectedTotal < 0 {
			expectedTotal = response.TotalRecords
		} else if response.TotalRecords != expectedTotal {
			return nil, fmt.Errorf("Lidarr history total changed while reading page %d", page)
		}
		for index, record := range response.Records {
			if record == nil || record.ID <= 0 || record.Date.IsZero() {
				return nil, fmt.Errorf("Lidarr history page %d record %d is invalid", page, index)
			}
			if _, duplicate := seen[record.ID]; duplicate {
				return nil, fmt.Errorf("Lidarr history contains duplicate record ID %d", record.ID)
			}
			seen[record.ID] = struct{}{}
			if record.EventType != trackFileImportedEvent || record.AlbumID != albumID ||
				(downloadID != "" && record.DownloadID != downloadID) {
				continue
			}
			if record.ArtistID <= 0 || record.TrackID <= 0 ||
				record.Data.DroppedPath == "" || record.Data.ImportedPath == "" {
				return nil, fmt.Errorf("Lidarr imported-track history record %d is incomplete", record.ID)
			}
			imports = append(imports, ImportedTrack{
				HistoryID: record.ID, AlbumID: record.AlbumID, ArtistID: record.ArtistID,
				TrackID: record.TrackID, DownloadID: record.DownloadID,
				DroppedPath: record.Data.DroppedPath, ImportedPath: record.Data.ImportedPath,
				OccurredAt: record.Date.UTC(),
			})
		}
		collected := page * response.PageSize
		if collected >= expectedTotal || len(response.Records) == 0 {
			sort.Slice(imports, func(left, right int) bool {
				return imports[left].HistoryID < imports[right].HistoryID
			})
			return imports, nil
		}
	}
	return nil, fmt.Errorf("Lidarr history exceeds %d records", maximumHistoryRecords)
}

func HighestImportedTrackHistoryID(imports []ImportedTrack) int64 {
	var highest int64
	for _, imported := range imports {
		if imported.HistoryID > highest {
			highest = imported.HistoryID
		}
	}
	return highest
}

type ImportedTrackMatch struct {
	TrackID        int64
	DownloadID     string
	DroppedPath    string
	AfterHistoryID int64
	NotBefore      time.Time
}

func FindImportedTrack(imports []ImportedTrack, match ImportedTrackMatch) (ImportedTrack, bool) {
	for _, imported := range imports {
		if imported.HistoryID > match.AfterHistoryID && imported.TrackID == match.TrackID &&
			(match.DownloadID == "" || imported.DownloadID == match.DownloadID) &&
			imported.DroppedPath == match.DroppedPath &&
			!imported.OccurredAt.Before(match.NotBefore) {
			return imported, true
		}
	}
	return ImportedTrack{}, false
}

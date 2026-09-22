package radarr

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"golift.io/starr"
	starrRadarr "golift.io/starr/radarr"
)

const (
	historyPageSize       = 250
	maximumHistoryPages   = 100
	maximumHistoryRecords = 10_000
)

var _ controller.RadarrHistoryReader = (*Client)(nil)

func (client *Client) ReadHistory(
	ctx context.Context,
	movieID int64,
	downloadID string,
) ([]controller.RadarrHistoryEvent, error) {
	rawRecords, err := client.readHistoryRecords(ctx, movieID, downloadID)
	if err != nil {
		return nil, err
	}
	records := make([]controller.RadarrHistoryEvent, len(rawRecords))
	for index, record := range rawRecords {
		mapped, err := mapHistoryRecord(record)
		if err != nil {
			return nil, fmt.Errorf("Radarr history record %d: %w", index, err)
		}
		records[index] = mapped
	}
	return records, nil
}

func (client *Client) readHistoryRecords(
	ctx context.Context,
	movieID int64,
	downloadID string,
) ([]*starrRadarr.HistoryRecord, error) {
	if err := validateHistoryQuery(movieID, downloadID); err != nil {
		return nil, err
	}

	records := make([]*starrRadarr.HistoryRecord, 0)
	seen := make(map[int64]struct{})
	expectedTotal := -1

	// Starr's all-history helper can truncate a requested count and owns the
	// pagination loop. Use its single-page operation so local bounds and snapshot
	// consistency remain enforced here, as they are for the queue reader.
	for page := 1; page <= maximumHistoryPages; page++ {
		response, err := client.api.GetHistoryPageContext(
			ctx,
			historyPageRequest(page, movieID, downloadID),
		)
		if err != nil {
			return nil, normalizeRequestError(
				fmt.Sprintf("read Radarr history page %d", page),
				err,
			)
		}
		if err := validateHistoryPage(page, response, expectedTotal, len(records)); err != nil {
			return nil, err
		}
		if expectedTotal == -1 {
			expectedTotal = response.TotalRecords
		}

		for index, record := range response.Records {
			if err := validateHistoryRecord(record, movieID, downloadID); err != nil {
				return nil, fmt.Errorf("Radarr history page %d record %d: %w", page, index, err)
			}
			if _, exists := seen[record.ID]; exists {
				return nil, fmt.Errorf("Radarr history contains duplicate record ID %d", record.ID)
			}
			seen[record.ID] = struct{}{}
			records = append(records, record)
		}

		switch {
		case len(records) == expectedTotal:
			sort.Slice(records, func(left, right int) bool {
				if records[left].Date.Equal(records[right].Date) {
					return records[left].ID < records[right].ID
				}
				return records[left].Date.Before(records[right].Date)
			})
			return records, nil
		case len(records) > expectedTotal:
			return nil, fmt.Errorf(
				"Radarr history returned %d records for a reported total of %d",
				len(records),
				expectedTotal,
			)
		case len(response.Records) == 0:
			return nil, fmt.Errorf(
				"Radarr history page %d was empty before the reported total of %d",
				page,
				expectedTotal,
			)
		}
	}

	return nil, fmt.Errorf("Radarr history exceeds %d pages", maximumHistoryPages)
}

func validateHistoryQuery(movieID int64, downloadID string) error {
	if movieID <= 0 {
		return fmt.Errorf("Radarr movie ID must be positive")
	}
	if downloadID == "" || strings.TrimSpace(downloadID) != downloadID ||
		strings.ContainsRune(downloadID, '\x00') {
		return fmt.Errorf("Radarr download ID is invalid")
	}
	return nil
}

func historyPageRequest(page int, movieID int64, downloadID string) *starr.PageReq {
	request := &starr.PageReq{
		Page:     page,
		PageSize: historyPageSize,
		SortKey:  "date",
		SortDir:  starr.SortAscend,
	}
	request.Set("movieIds", strconv.FormatInt(movieID, 10))
	request.Set("downloadId", downloadID)
	request.Set("includeMovie", "false")
	return request
}

func validateHistoryPage(
	expectedPage int,
	page *starrRadarr.History,
	expectedTotal int,
	collected int,
) error {
	if page == nil {
		return fmt.Errorf("Radarr history page %d is nil", expectedPage)
	}
	if page.Page != expectedPage {
		return fmt.Errorf(
			"Radarr history requested page %d but received page %d",
			expectedPage,
			page.Page,
		)
	}
	if page.PageSize <= 0 || page.PageSize > historyPageSize || len(page.Records) > page.PageSize {
		return fmt.Errorf("Radarr history page %d has invalid page size %d", expectedPage, page.PageSize)
	}
	if page.TotalRecords < 0 || page.TotalRecords > maximumHistoryRecords {
		return fmt.Errorf(
			"Radarr history page %d has invalid total %d",
			expectedPage,
			page.TotalRecords,
		)
	}
	if expectedTotal >= 0 && page.TotalRecords != expectedTotal {
		return fmt.Errorf(
			"Radarr history total changed from %d to %d while reading page %d",
			expectedTotal,
			page.TotalRecords,
			expectedPage,
		)
	}
	if collected+len(page.Records) > maximumHistoryRecords {
		return fmt.Errorf("Radarr history exceeds %d records", maximumHistoryRecords)
	}
	return nil
}

func validateHistoryRecord(
	record *starrRadarr.HistoryRecord,
	movieID int64,
	downloadID string,
) error {
	if record == nil {
		return fmt.Errorf("record is null")
	}
	if record.ID <= 0 {
		return fmt.Errorf("record ID must be positive")
	}
	if record.MovieID != movieID {
		return fmt.Errorf(
			"record movie ID %d does not match requested ID %d",
			record.MovieID,
			movieID,
		)
	}
	if record.DownloadID != downloadID {
		return fmt.Errorf("record download ID does not match request")
	}
	if record.Date.IsZero() {
		return fmt.Errorf("record date is missing")
	}
	if strings.TrimSpace(record.EventType) == "" {
		return fmt.Errorf("record event type is missing")
	}
	return nil
}

func mapHistoryRecord(
	record *starrRadarr.HistoryRecord,
) (controller.RadarrHistoryEvent, error) {
	if strings.TrimSpace(record.SourceTitle) == "" {
		return controller.RadarrHistoryEvent{}, fmt.Errorf("record source title is missing")
	}

	languages, err := mapLanguages(record.Languages)
	if err != nil {
		return controller.RadarrHistoryEvent{}, fmt.Errorf("record %w", err)
	}

	return controller.RadarrHistoryEvent{
		ID:          record.ID,
		MovieID:     record.MovieID,
		DownloadID:  record.DownloadID,
		EventType:   controller.RadarrHistoryEventType(record.EventType),
		OccurredAt:  record.Date.UTC(),
		SourceTitle: record.SourceTitle,
		Quality:     mapQuality(record.Quality),
		Languages:   languages,
	}, nil
}

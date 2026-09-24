package radarr

import (
	"context"
	"fmt"
	"math"
	"net/http"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
	"golift.io/starr"
	starrRadarr "golift.io/starr/radarr"
)

const (
	queuePageSize              = servarr.QueuePageSize
	maximumQueuePages          = servarr.MaximumQueuePages
	maximumQueueRecords        = servarr.MaximumQueueRecords
	maximumRadarrResponseBytes = servarr.MaximumResponseBytes
)

var errResponseTooLarge = servarr.ErrResponseTooLarge

type HTTPError = servarr.HTTPError

type Client struct {
	api *starrRadarr.Radarr
}

func New(baseURL, apiKey string, httpClient *http.Client) (*Client, error) {
	configuration, err := servarr.NewConfig("Radarr", baseURL, apiKey, httpClient)
	if err != nil {
		return nil, err
	}
	return &Client{api: starrRadarr.New(configuration)}, nil
}

var _ controller.RadarrQueueReader = (*Client)(nil)

func (client *Client) ReadQueue(ctx context.Context) ([]controller.RadarrQueueRecord, error) {
	observed, err := servarr.ReadQueue(ctx, "Radarr", client.readQueuePage)
	if err != nil {
		return nil, err
	}
	records := make([]controller.RadarrQueueRecord, len(observed))
	seen := make(map[int64]struct{}, len(observed))
	for index, item := range observed {
		mapped, mapErr := mapQueueRecord(item.record)
		if mapErr != nil {
			return nil, fmt.Errorf(
				"Radarr queue page %d record %d: %w",
				item.page,
				item.index,
				mapErr,
			)
		}
		if _, exists := seen[mapped.ID]; exists {
			return nil, fmt.Errorf("Radarr queue contains duplicate record ID %d", mapped.ID)
		}
		seen[mapped.ID] = struct{}{}
		records[index] = mapped
	}
	return records, nil
}

type queueRecord struct {
	page   int
	index  int
	record *starrRadarr.QueueRecord
}

func (client *Client) readQueuePage(
	ctx context.Context,
	page int,
	pageSize int,
) (servarr.QueuePage[queueRecord], error) {
	response, err := client.api.GetQueuePageContext(ctx, queuePageRequest(page, pageSize))
	if err != nil {
		return servarr.QueuePage[queueRecord]{}, normalizePageError(page, err)
	}
	if response == nil {
		return servarr.QueuePage[queueRecord]{}, fmt.Errorf("Radarr queue page %d is nil", page)
	}
	records := make([]queueRecord, len(response.Records))
	for index, record := range response.Records {
		records[index] = queueRecord{page: page, index: index, record: record}
	}
	return servarr.QueuePage[queueRecord]{
		Number:       response.Page,
		Size:         response.PageSize,
		TotalRecords: response.TotalRecords,
		Records:      records,
	}, nil
}

func queuePageRequest(page, pageSize int) *starr.PageReq {
	request := &starr.PageReq{
		Page:     page,
		PageSize: pageSize,
		// Starr defaults to timeleft, which changes while pages are being read.
		// Added is a documented Radarr sort key and is stable for a queue entry.
		SortKey: "added",
		SortDir: starr.SortAscend,
	}
	// Starr currently supplies the same unknown-item default. Set it explicitly
	// because unknown movie associations are essential repair evidence.
	request.Set("includeUnknownMovieItems", "true")
	request.Set("includeMovie", "false")
	return request
}

func mapQueueRecord(record *starrRadarr.QueueRecord) (controller.RadarrQueueRecord, error) {
	if record == nil {
		return controller.RadarrQueueRecord{}, fmt.Errorf("record is null")
	}
	if record.ID <= 0 {
		return controller.RadarrQueueRecord{}, fmt.Errorf("record ID must be positive")
	}
	if record.MovieID < 0 {
		return controller.RadarrQueueRecord{}, fmt.Errorf("movie ID must not be negative")
	}
	if invalidSize(record.Size) || invalidSize(record.Sizeleft) {
		return controller.RadarrQueueRecord{}, fmt.Errorf("record sizes must be finite and non-negative")
	}

	messages := make([]controller.RadarrStatusMessage, len(record.StatusMessages))
	for index, message := range record.StatusMessages {
		if message == nil {
			return controller.RadarrQueueRecord{}, fmt.Errorf("status message %d is null", index)
		}
		messages[index] = controller.RadarrStatusMessage{
			Title:    message.Title,
			Messages: append([]string(nil), message.Messages...),
		}
	}

	result := controller.RadarrQueueRecord{
		ID:                            record.ID,
		Title:                         record.Title,
		SizeBytes:                     record.Size,
		SizeRemainingBytes:            record.Sizeleft,
		TimeRemaining:                 record.Timeleft,
		Status:                        controller.QueueStatus(record.Status),
		TrackedDownloadStatus:         controller.TrackedDownloadStatus(record.TrackedDownloadStatus),
		TrackedDownloadState:          controller.TrackedDownloadState(record.TrackedDownloadState),
		StatusMessages:                messages,
		ErrorMessage:                  record.ErrorMessage,
		DownloadID:                    record.DownloadID,
		Protocol:                      controller.DownloadProtocol(record.Protocol),
		DownloadClient:                record.DownloadClient,
		Indexer:                       record.Indexer,
		OutputPath:                    normalizeQueueOutputPath(record.OutputPath),
		DownloadClientHasPostCategory: record.HasPostImportCategory,
	}
	// Starr represents Radarr's nullable movie ID and completion time as zero
	// values. Normalize those sentinels at the adapter boundary.
	if record.MovieID != 0 {
		movieID := record.MovieID
		result.MovieID = &movieID
	}
	// Radarr recalculates this as now + timeleft, including for completed
	// records whose timeleft is zero. That moving value is not a completion fact.
	if record.Status != "completed" && !record.EstimatedCompletionTime.IsZero() {
		completion := record.EstimatedCompletionTime
		result.EstimatedCompletionTime = &completion
	}

	return result, nil
}

func normalizeQueueOutputPath(path string) string {
	// Radarr may retain a directory's trailing separator in queue records. Drop
	// only trailing separators here; later validation still rejects other
	// non-canonical or unsafe paths instead of silently cleaning them.
	trimmed := strings.TrimRight(path, "/")
	if trimmed == "" {
		return path
	}
	return trimmed
}

func invalidSize(value float64) bool {
	return value < 0 || math.IsNaN(value) || math.IsInf(value, 0)
}

func normalizePageError(page int, err error) error {
	return normalizeRequestError(fmt.Sprintf("read Radarr queue page %d", page), err)
}

func normalizeRequestError(operation string, err error) error {
	return servarr.NormalizeRequestError("Radarr", operation, err)
}

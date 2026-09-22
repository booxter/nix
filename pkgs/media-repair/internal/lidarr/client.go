package lidarr

import (
	"context"
	"fmt"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/servarr"
	"golift.io/starr"
	starrLidarr "golift.io/starr/lidarr"
)

type QueueStatus string
type TrackedDownloadStatus string
type DownloadProtocol string

type StatusMessage struct {
	Title    string
	Messages []string
}

type QueueRecord struct {
	ID                            int64
	ArtistID                      *int64
	AlbumID                       *int64
	Title                         string
	SizeBytes                     float64
	SizeRemainingBytes            float64
	TimeRemaining                 string
	EstimatedCompletionTime       *time.Time
	Status                        QueueStatus
	TrackedDownloadStatus         TrackedDownloadStatus
	StatusMessages                []StatusMessage
	ErrorMessage                  string
	DownloadID                    string
	Protocol                      DownloadProtocol
	DownloadClient                string
	Indexer                       string
	OutputPath                    string
	DownloadClientHasPostCategory bool
}

type Client struct {
	api *starrLidarr.Lidarr
}

func New(baseURL, apiKey string, httpClient *http.Client) (*Client, error) {
	configuration, err := servarr.NewConfig("Lidarr", baseURL, apiKey, httpClient)
	if err != nil {
		return nil, err
	}
	return &Client{api: starrLidarr.New(configuration)}, nil
}

func (client *Client) ReadQueue(ctx context.Context) ([]QueueRecord, error) {
	observed, err := servarr.ReadQueue(ctx, "Lidarr", client.readQueuePage)
	if err != nil {
		return nil, err
	}
	records := make([]QueueRecord, len(observed))
	seen := make(map[int64]struct{}, len(observed))
	for index, item := range observed {
		mapped, mapErr := mapQueueRecord(item.record)
		if mapErr != nil {
			return nil, fmt.Errorf(
				"Lidarr queue page %d record %d: %w",
				item.page,
				item.index,
				mapErr,
			)
		}
		if _, exists := seen[mapped.ID]; exists {
			return nil, fmt.Errorf("Lidarr queue contains duplicate record ID %d", mapped.ID)
		}
		seen[mapped.ID] = struct{}{}
		records[index] = mapped
	}
	return records, nil
}

type queueRecord struct {
	page   int
	index  int
	record *starrLidarr.QueueRecord
}

func (client *Client) readQueuePage(
	ctx context.Context,
	page int,
	pageSize int,
) (servarr.QueuePage[queueRecord], error) {
	request := &starr.PageReq{
		Page: page, PageSize: pageSize, SortKey: "added", SortDir: starr.SortAscend,
	}
	request.Set("includeUnknownArtistItems", "true")
	request.Set("includeArtist", "false")
	response, err := client.api.GetQueuePageContext(ctx, request)
	if err != nil {
		return servarr.QueuePage[queueRecord]{}, servarr.NormalizeRequestError(
			"Lidarr",
			fmt.Sprintf("read Lidarr queue page %d", page),
			err,
		)
	}
	if response == nil {
		return servarr.QueuePage[queueRecord]{}, fmt.Errorf("Lidarr queue page %d is nil", page)
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

func mapQueueRecord(record *starrLidarr.QueueRecord) (QueueRecord, error) {
	if record == nil {
		return QueueRecord{}, fmt.Errorf("record is null")
	}
	if record.ID <= 0 {
		return QueueRecord{}, fmt.Errorf("record ID must be positive")
	}
	if record.ArtistID < 0 || record.AlbumID < 0 {
		return QueueRecord{}, fmt.Errorf("artist and album IDs must not be negative")
	}
	if invalidSize(record.Size) || invalidSize(record.Sizeleft) {
		return QueueRecord{}, fmt.Errorf("record sizes must be finite and non-negative")
	}
	messages := make([]StatusMessage, len(record.StatusMessages))
	for index, message := range record.StatusMessages {
		if message == nil {
			return QueueRecord{}, fmt.Errorf("status message %d is null", index)
		}
		messages[index] = StatusMessage{
			Title: message.Title, Messages: append([]string(nil), message.Messages...),
		}
	}
	result := QueueRecord{
		ID:                            record.ID,
		Title:                         record.Title,
		SizeBytes:                     record.Size,
		SizeRemainingBytes:            record.Sizeleft,
		TimeRemaining:                 record.Timeleft,
		Status:                        QueueStatus(record.Status),
		TrackedDownloadStatus:         TrackedDownloadStatus(record.TrackedDownloadStatus),
		StatusMessages:                messages,
		ErrorMessage:                  record.ErrorMessage,
		DownloadID:                    record.DownloadID,
		Protocol:                      DownloadProtocol(record.Protocol),
		DownloadClient:                record.DownloadClient,
		Indexer:                       record.Indexer,
		OutputPath:                    normalizeOutputPath(record.OutputPath),
		DownloadClientHasPostCategory: record.HasPostImportCategory,
	}
	if record.ArtistID != 0 {
		artistID := record.ArtistID
		result.ArtistID = &artistID
	}
	if record.AlbumID != 0 {
		albumID := record.AlbumID
		result.AlbumID = &albumID
	}
	if record.Status != "completed" && !record.EstimatedCompletionTime.IsZero() {
		completion := record.EstimatedCompletionTime
		result.EstimatedCompletionTime = &completion
	}
	return result, nil
}

func normalizeOutputPath(path string) string {
	trimmed := strings.TrimRight(path, "/")
	if trimmed == "" {
		return path
	}
	return trimmed
}

func invalidSize(value float64) bool {
	return value < 0 || math.IsNaN(value) || math.IsInf(value, 0)
}

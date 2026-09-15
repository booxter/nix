package radarr

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"golift.io/starr"
	starrRadarr "golift.io/starr/radarr"
)

const (
	queuePageSize              = 250
	maximumQueuePages          = 100
	maximumQueueRecords        = 10_000
	maximumRadarrResponseBytes = 8 << 20
)

var errResponseTooLarge = fmt.Errorf(
	"Radarr response exceeds %d bytes",
	maximumRadarrResponseBytes,
)

type Client struct {
	api *starrRadarr.Radarr
}

type HTTPError struct {
	StatusCode int
}

func (err *HTTPError) Error() string {
	return fmt.Sprintf("Radarr returned HTTP status %d", err.StatusCode)
}

func New(baseURL, apiKey string, httpClient *http.Client) (*Client, error) {
	if httpClient == nil {
		return nil, fmt.Errorf("Radarr HTTP client is required")
	}
	if apiKey == "" {
		return nil, fmt.Errorf("Radarr API key is required")
	}
	parsedURL, err := url.Parse(baseURL)
	if err != nil {
		return nil, fmt.Errorf("parse Radarr URL: %w", err)
	}
	if !parsedURL.IsAbs() || parsedURL.Host == "" {
		return nil, fmt.Errorf("Radarr URL must be absolute")
	}
	if parsedURL.Scheme != "http" && parsedURL.Scheme != "https" {
		return nil, fmt.Errorf("Radarr URL scheme must be http or https")
	}
	// Starr accepts userinfo and URL parameters, but keeping credentials solely in
	// headers prevents them from appearing in transport errors and diagnostics.
	if parsedURL.User != nil || parsedURL.RawQuery != "" || parsedURL.Fragment != "" {
		return nil, fmt.Errorf("Radarr URL must not contain credentials, query, or fragment")
	}

	configuration := &starr.Config{
		APIKey: apiKey,
		URL:    strings.TrimSuffix(baseURL, "/"),
		// Starr decodes responses directly and reads error bodies in full, so cap
		// bodies in the injected transport before the library can consume them.
		Client: withResponseLimit(httpClient),
	}

	return &Client{api: starrRadarr.New(configuration)}, nil
}

var _ controller.RadarrQueueReader = (*Client)(nil)

func (client *Client) ReadQueue(ctx context.Context) ([]controller.RadarrQueueRecord, error) {
	records := make([]controller.RadarrQueueRecord, 0)
	seen := make(map[int64]struct{})
	expectedTotal := -1

	// Use Starr's single-page operation rather than its all-records helper so a
	// corrupt or changing total cannot drive unbounded requests or allocation.
	for page := 1; page <= maximumQueuePages; page++ {
		response, err := client.api.GetQueuePageContext(ctx, queuePageRequest(page))
		if err != nil {
			return nil, normalizePageError(page, err)
		}
		if err := validatePage(page, response, expectedTotal, len(records)); err != nil {
			return nil, err
		}
		if expectedTotal == -1 {
			expectedTotal = response.TotalRecords
		}

		for index, record := range response.Records {
			mapped, err := mapQueueRecord(record)
			if err != nil {
				return nil, fmt.Errorf("Radarr queue page %d record %d: %w", page, index, err)
			}
			if _, exists := seen[mapped.ID]; exists {
				return nil, fmt.Errorf("Radarr queue contains duplicate record ID %d", mapped.ID)
			}
			seen[mapped.ID] = struct{}{}
			records = append(records, mapped)
		}

		switch {
		case len(records) == expectedTotal:
			return records, nil
		case len(records) > expectedTotal:
			return nil, fmt.Errorf(
				"Radarr queue returned %d records for a reported total of %d",
				len(records),
				expectedTotal,
			)
		case len(response.Records) == 0:
			return nil, fmt.Errorf(
				"Radarr queue page %d was empty before the reported total of %d",
				page,
				expectedTotal,
			)
		}
	}

	return nil, fmt.Errorf("Radarr queue exceeds %d pages", maximumQueuePages)
}

func queuePageRequest(page int) *starr.PageReq {
	request := &starr.PageReq{
		Page:     page,
		PageSize: queuePageSize,
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

func validatePage(
	expectedPage int,
	page *starrRadarr.Queue,
	expectedTotal int,
	collected int,
) error {
	if page == nil {
		return fmt.Errorf("Radarr queue page %d is nil", expectedPage)
	}
	if page.Page != expectedPage {
		return fmt.Errorf(
			"Radarr queue requested page %d but received page %d",
			expectedPage,
			page.Page,
		)
	}
	if page.PageSize <= 0 || page.PageSize > queuePageSize || len(page.Records) > page.PageSize {
		return fmt.Errorf("Radarr queue page %d has invalid page size %d", expectedPage, page.PageSize)
	}
	if page.TotalRecords < 0 || page.TotalRecords > maximumQueueRecords {
		return fmt.Errorf(
			"Radarr queue page %d has invalid total %d",
			expectedPage,
			page.TotalRecords,
		)
	}
	// A changing total means the paginated result is not one coherent observation;
	// fail this poll so the controller can obtain a fresh snapshot next time.
	if expectedTotal >= 0 && page.TotalRecords != expectedTotal {
		return fmt.Errorf(
			"Radarr queue total changed from %d to %d while reading page %d",
			expectedTotal,
			page.TotalRecords,
			expectedPage,
		)
	}
	if collected+len(page.Records) > maximumQueueRecords {
		return fmt.Errorf("Radarr queue exceeds %d records", maximumQueueRecords)
	}
	return nil
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
	if errors.Is(err, errResponseTooLarge) {
		return fmt.Errorf("%s: %w", operation, errResponseTooLarge)
	}
	var requestError *starr.ReqError
	if errors.As(err, &requestError) {
		// Starr retains response bodies in ReqError. Return only the status so an
		// upstream error page cannot leak credentials or unrelated server data.
		return fmt.Errorf(
			"%s: %w",
			operation,
			&HTTPError{StatusCode: requestError.Code},
		)
	}
	return fmt.Errorf("%s: %w", operation, err)
}

func withResponseLimit(client *http.Client) *http.Client {
	limited := *client
	transport := limited.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	limited.Transport = &responseLimitTransport{
		next:  transport,
		limit: maximumRadarrResponseBytes,
	}
	return &limited
}

type responseLimitTransport struct {
	next  http.RoundTripper
	limit int64
}

func (transport *responseLimitTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := transport.next.RoundTrip(request)
	if err != nil {
		return nil, err
	}
	if response.Body == nil {
		return response, nil
	}
	if response.ContentLength > transport.limit {
		_ = response.Body.Close()
		return nil, errResponseTooLarge
	}
	response.Body = &limitedReadCloser{
		body:      response.Body,
		remaining: transport.limit,
	}
	return response, nil
}

type limitedReadCloser struct {
	body      io.ReadCloser
	remaining int64
}

func (reader *limitedReadCloser) Read(buffer []byte) (int, error) {
	if reader.remaining > 0 {
		if int64(len(buffer)) > reader.remaining {
			buffer = buffer[:reader.remaining]
		}
		read, err := reader.body.Read(buffer)
		reader.remaining -= int64(read)
		return read, err
	}

	var extra [1]byte
	read, err := reader.body.Read(extra[:])
	if read > 0 {
		return 0, errResponseTooLarge
	}
	return 0, err
}

func (reader *limitedReadCloser) Close() error {
	return reader.body.Close()
}

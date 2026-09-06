package radarr

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

func TestReadQueue(t *testing.T) {
	t.Parallel()

	requestedPages := 0
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requestedPages++
		if request.Method != http.MethodGet || request.URL.Path != "/api/v3/queue" {
			t.Errorf("request = %s %s", request.Method, request.URL.Path)
			http.Error(writer, "unexpected request", http.StatusBadRequest)
			return
		}
		if key := request.Header.Get("X-Api-Key"); key != "test-api-key" {
			t.Errorf("X-Api-Key = %q", key)
			http.Error(writer, "missing API key", http.StatusUnauthorized)
			return
		}
		query := request.URL.Query()
		if query.Has("apikey") {
			t.Error("API key was sent in the query string")
		}
		for name, expected := range map[string]string{
			"pageSize":                 strconv.Itoa(queuePageSize),
			"sortKey":                  "added",
			"sortDirection":            "ascending",
			"includeUnknownMovieItems": "true",
			"includeMovie":             "false",
		} {
			if actual := query.Get(name); actual != expected {
				t.Errorf("query %s = %q, want %q", name, actual, expected)
			}
		}

		page, err := strconv.Atoi(query.Get("page"))
		if err != nil || page < 1 || page > 2 {
			t.Errorf("page = %q", query.Get("page"))
			http.Error(writer, "invalid page", http.StatusBadRequest)
			return
		}
		data, err := os.ReadFile(filepath.Join("testdata", fmt.Sprintf("queue-page-%d.json", page)))
		if err != nil {
			t.Error(err)
			http.Error(writer, "fixture unavailable", http.StatusInternalServerError)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write(data)
	}))
	defer server.Close()

	client, err := New(server.URL, "test-api-key", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	records, err := client.ReadQueue(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if requestedPages != 2 {
		t.Fatalf("requested pages = %d", requestedPages)
	}
	if len(records) != 3 {
		t.Fatalf("records = %d", len(records))
	}
	first := records[0]
	if first.ID != 101 || first.MovieID == nil || *first.MovieID != 42 {
		t.Fatalf("first identity = ID %d, MovieID %v", first.ID, first.MovieID)
	}
	if first.EstimatedCompletionTime == nil ||
		!first.EstimatedCompletionTime.Equal(time.Date(2026, 9, 6, 12, 0, 0, 0, time.UTC)) {
		t.Fatalf("completion time = %v", first.EstimatedCompletionTime)
	}
	if first.Title != "Example.Movie.2026.Part1.mkv" ||
		first.SizeBytes != 4294967296 ||
		first.SizeRemainingBytes != 0 ||
		first.TimeRemaining != "00:00:00" ||
		first.Status != controller.QueueStatus("completed") ||
		first.TrackedDownloadStatus != controller.TrackedDownloadStatus("warning") ||
		first.TrackedDownloadState != controller.TrackedDownloadState("importBlocked") ||
		first.ErrorMessage != "Import failed" ||
		first.DownloadID != "ABCDEF0123456789" ||
		first.Protocol != controller.DownloadProtocol("torrent") ||
		first.DownloadClient != "Transmission" ||
		first.Indexer != "Example Indexer" ||
		first.OutputPath != "/downloads/Example.Movie.2026" ||
		!first.DownloadClientHasPostCategory {
		t.Fatalf("first record was not mapped: %#v", first)
	}
	expectedMessages := []controller.RadarrStatusMessage{
		{Title: "Import failed", Messages: []string{"No files found are eligible for import"}},
	}
	if !reflect.DeepEqual(first.StatusMessages, expectedMessages) {
		t.Fatalf("status messages = %#v", first.StatusMessages)
	}
	if records[1].MovieID != nil || records[1].EstimatedCompletionTime != nil {
		t.Fatalf("nullable fields = MovieID %v, completion %v", records[1].MovieID, records[1].EstimatedCompletionTime)
	}
	if records[2].Status != controller.QueueStatus("futureQueueStatus") ||
		records[2].TrackedDownloadStatus != controller.TrackedDownloadStatus("futureTrackedStatus") ||
		records[2].TrackedDownloadState != controller.TrackedDownloadState("futureTrackedState") ||
		records[2].Protocol != controller.DownloadProtocol("futureProtocol") {
		t.Fatalf("future values were not preserved: %#v", records[2])
	}
}

func TestNewRejectsInvalidConfiguration(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		baseURL    string
		apiKey     string
		httpClient *http.Client
	}{
		{name: "nil client", baseURL: "http://radarr.example", apiKey: "key"},
		{name: "empty key", baseURL: "http://radarr.example", httpClient: http.DefaultClient},
		{name: "relative URL", baseURL: "/radarr", apiKey: "key", httpClient: http.DefaultClient},
		{name: "unsupported scheme", baseURL: "file:///radarr", apiKey: "key", httpClient: http.DefaultClient},
		{name: "credentials", baseURL: "http://user:password@radarr.example", apiKey: "key", httpClient: http.DefaultClient},
		{name: "query", baseURL: "http://radarr.example?secret=value", apiKey: "key", httpClient: http.DefaultClient},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if _, err := New(test.baseURL, test.apiKey, test.httpClient); err == nil {
				t.Fatal("invalid configuration was accepted")
			}
		})
	}
}

func TestReadQueueRejectsInconsistentPagination(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		handler http.HandlerFunc
		want    string
	}{
		{
			name: "duplicate record",
			handler: queueHandler(func(request *http.Request) testQueuePage {
				return testQueuePage{
					Page: 1, PageSize: queuePageSize, TotalRecords: 2,
					Records: []*testQueueRecord{{ID: 1}, {ID: 1}},
				}
			}),
			want: "duplicate record ID 1",
		},
		{
			name: "changing total",
			handler: queueHandler(func(request *http.Request) testQueuePage {
				page, _ := strconv.Atoi(request.URL.Query().Get("page"))
				total := 2
				if page == 2 {
					total = 3
				}
				return testQueuePage{
					Page: page, PageSize: queuePageSize, TotalRecords: total,
					Records: []*testQueueRecord{{ID: int64(page)}},
				}
			}),
			want: "total changed from 2 to 3",
		},
		{
			name: "null record",
			handler: queueHandler(func(_ *http.Request) testQueuePage {
				return testQueuePage{
					Page: 1, PageSize: queuePageSize, TotalRecords: 1,
					Records: []*testQueueRecord{nil},
				}
			}),
			want: "record is null",
		},
		{
			name: "excessive total",
			handler: queueHandler(func(_ *http.Request) testQueuePage {
				return testQueuePage{
					Page: 1, PageSize: queuePageSize, TotalRecords: maximumQueueRecords + 1,
					Records: []*testQueueRecord{},
				}
			}),
			want: "invalid total",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			server := httptest.NewServer(test.handler)
			defer server.Close()
			client, err := New(server.URL, "key", server.Client())
			if err != nil {
				t.Fatal(err)
			}
			_, err = client.ReadQueue(context.Background())
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestReadQueueSanitizesHTTPError(t *testing.T) {
	t.Parallel()

	const responseSecret = "do-not-expose-this-response"
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		http.Error(writer, responseSecret, http.StatusInternalServerError)
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	_, err = client.ReadQueue(context.Background())
	if err == nil || strings.Contains(err.Error(), responseSecret) {
		t.Fatalf("error = %v", err)
	}
	var httpError *HTTPError
	if !errors.As(err, &httpError) || httpError.StatusCode != http.StatusInternalServerError {
		t.Fatalf("HTTP error = %#v", httpError)
	}
}

func TestReadQueueRejectsOversizedResponse(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Length", strconv.Itoa(maximumRadarrResponseBytes+1))
		_, _ = writer.Write([]byte("{}"))
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	_, err = client.ReadQueue(context.Background())
	if !errors.Is(err, errResponseTooLarge) {
		t.Fatalf("error = %v", err)
	}
}

func TestReadQueueRejectsMalformedResponse(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"page":`))
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	if _, err := client.ReadQueue(context.Background()); err == nil {
		t.Fatal("malformed response was accepted")
	}
}

func TestReadQueuePropagatesCancellation(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writeJSON(t, writer, testQueuePage{Page: 1, PageSize: queuePageSize})
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err = client.ReadQueue(ctx)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v", err)
	}
}

type testQueuePage struct {
	Page          int                `json:"page"`
	PageSize      int                `json:"pageSize"`
	SortKey       string             `json:"sortKey"`
	SortDirection string             `json:"sortDirection"`
	TotalRecords  int                `json:"totalRecords"`
	Records       []*testQueueRecord `json:"records"`
}

type testQueueRecord struct {
	ID int64 `json:"id"`
}

func queueHandler(page func(*http.Request) testQueuePage) http.HandlerFunc {
	return func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(page(request))
	}
}

func writeJSON(t *testing.T, writer http.ResponseWriter, value any) {
	t.Helper()
	writer.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(writer).Encode(value); err != nil {
		t.Error(err)
	}
}

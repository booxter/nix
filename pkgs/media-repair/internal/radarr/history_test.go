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

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

const testHistoryDownloadID = "ABCDEF0123456789"

func TestReadHistory(t *testing.T) {
	t.Parallel()

	requestedPages := 0
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requestedPages++
		assertHistoryRequest(t, request, requestedPages, 42, testHistoryDownloadID)
		data, err := os.ReadFile(filepath.Join("testdata", fmt.Sprintf("history-page-%d.json", requestedPages)))
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

	records, err := client.ReadHistory(context.Background(), 42, testHistoryDownloadID)
	if err != nil {
		t.Fatal(err)
	}
	if requestedPages != 2 || len(records) != 3 {
		t.Fatalf("requested pages = %d, records = %d", requestedPages, len(records))
	}
	if records[0].ID != 501 || records[1].ID != 502 || records[2].ID != 503 {
		t.Fatalf("record order = %d, %d, %d", records[0].ID, records[1].ID, records[2].ID)
	}
	first := records[0]
	if first.MovieID != 42 || first.DownloadID != testHistoryDownloadID ||
		first.EventType != "grabbed" || first.SourceTitle != "Example.Movie.2026.1080p.BluRay" ||
		!first.OccurredAt.Equal(time.Date(2026, 9, 6, 16, 0, 0, 0, time.UTC)) ||
		!reflect.DeepEqual(first.Quality, &controller.RadarrQualityModel{
			Quality: controller.RadarrQuality{
				ID: 7, Name: "Bluray-1080p", Source: "bluray",
				Resolution: 1080, Modifier: "none",
			},
			Revision: &controller.RadarrQualityRevision{Version: 1},
		}) ||
		!reflect.DeepEqual(first.Languages, []controller.RadarrLanguage{{ID: 1, Name: "English"}}) {
		t.Fatalf("first record = %#v", first)
	}
	if records[2].EventType != "futureEventType" || records[2].Quality != nil ||
		records[2].Languages == nil {
		t.Fatalf("future/optional fields = %#v", records[2])
	}
}

func TestReadHistoryRejectsInvalidArguments(t *testing.T) {
	t.Parallel()

	client, err := New("http://radarr.example", "key", http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.ReadHistory(context.Background(), 0, "download"); err == nil {
		t.Fatal("invalid movie ID was accepted")
	}
	if _, err := client.ReadHistory(context.Background(), 42, " download "); err == nil {
		t.Fatal("invalid download ID was accepted")
	}
}

func TestReadHistoryRejectsInconsistentResponse(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		page testHistoryPage
		want string
	}{
		{
			name: "duplicate record",
			page: testHistoryPage{
				Page: 1, PageSize: historyPageSize, TotalRecords: 2,
				Records: []*testHistoryRecord{
					validHistoryRecord(1),
					validHistoryRecord(1),
				},
			},
			want: "duplicate record ID 1",
		},
		{
			name: "null record",
			page: testHistoryPage{
				Page: 1, PageSize: historyPageSize, TotalRecords: 1,
				Records: []*testHistoryRecord{nil},
			},
			want: "record is null",
		},
		{
			name: "wrong movie",
			page: testHistoryPage{
				Page: 1, PageSize: historyPageSize, TotalRecords: 1,
				Records: []*testHistoryRecord{
					{
						ID: 1, MovieID: 43, DownloadID: testHistoryDownloadID,
						Date: time.Now(), EventType: "grabbed", SourceTitle: "Movie",
					},
				},
			},
			want: "movie ID 43 does not match requested ID 42",
		},
		{
			name: "wrong download",
			page: testHistoryPage{
				Page: 1, PageSize: historyPageSize, TotalRecords: 1,
				Records: []*testHistoryRecord{
					{
						ID: 1, MovieID: 42, DownloadID: "different-download",
						Date: time.Now(), EventType: "grabbed", SourceTitle: "Movie",
					},
				},
			},
			want: "download ID does not match request",
		},
		{
			name: "excessive total",
			page: testHistoryPage{
				Page: 1, PageSize: historyPageSize, TotalRecords: maximumHistoryRecords + 1,
				Records: []*testHistoryRecord{},
			},
			want: "invalid total",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			server := httptest.NewServer(historyHandler(test.page))
			defer server.Close()
			client, err := New(server.URL, "key", server.Client())
			if err != nil {
				t.Fatal(err)
			}
			_, err = client.ReadHistory(context.Background(), 42, testHistoryDownloadID)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestReadHistorySanitizesHTTPError(t *testing.T) {
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

	_, err = client.ReadHistory(context.Background(), 42, testHistoryDownloadID)
	if err == nil || strings.Contains(err.Error(), responseSecret) {
		t.Fatalf("error = %v", err)
	}
	var httpError *HTTPError
	if !errors.As(err, &httpError) || httpError.StatusCode != http.StatusInternalServerError {
		t.Fatalf("HTTP error = %#v", httpError)
	}
}

func TestReadHistoryRejectsMalformedResponse(t *testing.T) {
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

	if _, err := client.ReadHistory(context.Background(), 42, testHistoryDownloadID); err == nil {
		t.Fatal("malformed response was accepted")
	}
}

type testHistoryPage struct {
	Page          int                  `json:"page"`
	PageSize      int                  `json:"pageSize"`
	SortKey       string               `json:"sortKey"`
	SortDirection string               `json:"sortDirection"`
	TotalRecords  int                  `json:"totalRecords"`
	Records       []*testHistoryRecord `json:"records"`
}

type testHistoryRecord struct {
	ID          int64             `json:"id"`
	MovieID     int64             `json:"movieId"`
	DownloadID  string            `json:"downloadId"`
	Date        time.Time         `json:"date"`
	EventType   string            `json:"eventType"`
	SourceTitle string            `json:"sourceTitle"`
	Data        map[string]string `json:"data,omitempty"`
}

func validHistoryRecord(id int64) *testHistoryRecord {
	return &testHistoryRecord{
		ID: id, MovieID: 42, DownloadID: testHistoryDownloadID,
		Date:      time.Date(2026, 9, 6, 12, 0, 0, 0, time.UTC),
		EventType: "grabbed", SourceTitle: "Movie",
	}
}

func historyHandler(page testHistoryPage) http.HandlerFunc {
	return func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(page)
	}
}

func assertHistoryRequest(
	t *testing.T,
	request *http.Request,
	page int,
	movieID int64,
	downloadID string,
) {
	t.Helper()
	if request.Method != http.MethodGet || request.URL.Path != "/api/v3/history" {
		t.Errorf("request = %s %s", request.Method, request.URL.Path)
	}
	if key := request.Header.Get("X-Api-Key"); key != "test-api-key" {
		t.Errorf("X-Api-Key = %q", key)
	}
	want := map[string]string{
		"page":          strconv.Itoa(page),
		"pageSize":      strconv.Itoa(historyPageSize),
		"sortKey":       "date",
		"sortDirection": "ascending",
		"movieIds":      strconv.FormatInt(movieID, 10),
		"downloadId":    downloadID,
		"includeMovie":  "false",
	}
	query := request.URL.Query()
	if query.Has("apikey") {
		t.Error("API key was sent in the query string")
	}
	for name, value := range want {
		if query.Get(name) != value {
			t.Errorf("query %s = %q, want %q", name, query.Get(name), value)
		}
	}
}

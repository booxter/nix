package lidarr

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

func TestReadQueueUsesSharedBoundedPagination(t *testing.T) {
	t.Parallel()

	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		requests++
		if request.URL.Path != "/api/v1/queue" || request.Header.Get("X-Api-Key") != "key" {
			http.Error(writer, "bad request", http.StatusBadRequest)
			return
		}
		query := request.URL.Query()
		if query.Get("pageSize") != strconv.Itoa(servarr.QueuePageSize) ||
			query.Get("sortKey") != "added" ||
			query.Get("sortDirection") != "ascending" ||
			query.Get("includeUnknownArtistItems") != "true" ||
			query.Get("includeArtist") != "false" {
			t.Errorf("query = %v", query)
		}
		page, err := strconv.Atoi(query.Get("page"))
		if err != nil || page < 1 || page > 2 {
			http.Error(writer, "bad page", http.StatusBadRequest)
			return
		}
		record := map[string]any{
			"id": page, "artistId": 20, "albumId": 30,
			"title": "Album", "size": 100, "sizeleft": 0,
			"status": "completed", "trackedDownloadStatus": "warning",
			"statusMessages": []map[string]any{{
				"title": "Import failed", "messages": []string{"No files found"},
			}},
			"downloadId": "download", "protocol": "usenet",
			"downloadClient": "SABnzbd", "indexer": "Indexer",
			"outputPath":                          "/downloads/Album/",
			"downloadClientHasPostImportCategory": true,
		}
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"page": page, "pageSize": servarr.QueuePageSize,
			"totalRecords": 2, "records": []any{record},
		})
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	records, err := client.ReadQueue(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if requests != 2 || len(records) != 2 {
		t.Fatalf("requests = %d, records = %d", requests, len(records))
	}
	first := records[0]
	if first.ID != 1 || first.ArtistID == nil || *first.ArtistID != 20 ||
		first.AlbumID == nil || *first.AlbumID != 30 || first.OutputPath != "/downloads/Album" ||
		len(first.StatusMessages) != 1 || first.EstimatedCompletionTime != nil {
		t.Fatalf("first record = %#v", first)
	}
}

func TestReadQueueRejectsInvalidRecords(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(
		writer http.ResponseWriter,
		_ *http.Request,
	) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{
          "page":1,"pageSize":250,"totalRecords":1,"records":[{"id":0}]
        }`))
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.ReadQueue(context.Background()); err == nil {
		t.Fatal("invalid record was accepted")
	}
}

func TestReadQueueSanitizesHTTPFailures(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(
		writer http.ResponseWriter,
		_ *http.Request,
	) {
		http.Error(writer, "secret response", http.StatusInternalServerError)
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.ReadQueue(context.Background())
	var httpError *servarr.HTTPError
	if !errors.As(err, &httpError) || httpError.Service != "Lidarr" ||
		httpError.StatusCode != http.StatusInternalServerError {
		t.Fatalf("error = %v", err)
	}
}

func TestFinalizeQueueOnlyRemovesLidarrTracking(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		if request.Method != http.MethodDelete || request.URL.Path != "/api/v1/queue/42" {
			t.Errorf("request = %s %s", request.Method, request.URL.Path)
			http.Error(writer, "bad request", http.StatusBadRequest)
			return
		}
		query := request.URL.Query()
		if query.Get("removeFromClient") != "false" || query.Get("blocklist") != "false" ||
			query.Get("skipRedownload") != "true" || query.Get("changeCategory") != "false" {
			t.Errorf("query = %v", query)
			http.Error(writer, "bad query", http.StatusBadRequest)
			return
		}
		writer.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	if err := client.FinalizeQueue(context.Background(), 42); err != nil {
		t.Fatal(err)
	}
}

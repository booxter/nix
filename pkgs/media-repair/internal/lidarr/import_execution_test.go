package lidarr

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/servarr"
	"golift.io/starr"
	starrLidarr "golift.io/starr/lidarr"
)

func TestRequestManualImportUsesExactSelectedTracks(t *testing.T) {
	t.Parallel()
	var observed starrLidarr.ManualImportCommandRequest
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/api/v1/command" {
			t.Errorf("request = %s %s", request.Method, request.URL.Path)
		}
		if err := json.NewDecoder(request.Body).Decode(&observed); err != nil {
			t.Error(err)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"id":81,"name":"ManualImport","status":"queued"}`))
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	quality := &starr.Quality{Quality: &starr.BaseQuality{ID: 4, Name: "MP3-320"}}
	command, err := client.RequestManualImport(context.Background(), ManualImportCommand{
		Files: []ManualImportCommandFile{
			{
				Path: "/downloads/staged/01.mp3", ArtistID: 2, AlbumID: 3,
				AlbumReleaseID: 7, TrackID: 11, Quality: quality,
				DisableReleaseSwitching: false,
			},
			{
				Path: "/downloads/staged/02.mp3", ArtistID: 2, AlbumID: 3,
				AlbumReleaseID: 7, TrackID: 12, Quality: quality,
				DisableReleaseSwitching: false,
			},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if command.ID != 81 || command.Status != servarr.CommandQueued ||
		observed.Name != "ManualImport" || observed.ImportMode != "copy" ||
		observed.ReplaceExistingFiles || len(observed.Files) != 2 {
		t.Fatalf("command = %#v, request = %#v", command, observed)
	}
	if len(observed.Files[0].TrackIDs) != 1 || observed.Files[0].TrackIDs[0] != 11 ||
		observed.Files[0].AlbumReleaseID != 7 || observed.Files[0].DownloadID != "" ||
		observed.Files[0].DisableReleaseSwitching {
		t.Fatalf("first file = %#v", observed.Files[0])
	}
}

func TestReadImportedTracksWithoutDownloadFilter(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Query().Has("downloadId") {
			t.Errorf("query = %v", request.URL.Query())
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{
			"page":1,"pageSize":250,"totalRecords":1,
			"records":[{
				"id":91,"albumId":3,"artistId":2,"trackId":11,
				"downloadId":"","eventType":"trackFileImported",
				"date":"2026-09-22T12:00:00Z",
				"data":{"droppedPath":"/downloads/staged/01.mp3","importedPath":"/music/01.mp3"}
			}]
		}`))
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	imports, err := client.ReadImportedTracks(context.Background(), 3, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(imports) != 1 || imports[0].DownloadID != "" || imports[0].TrackID != 11 {
		t.Fatalf("imports = %#v", imports)
	}
}

func TestRecoverAlbumIdentity(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		query := request.URL.Query()
		if query.Get("downloadId") != "download" || query.Has("albumId") || query.Has("eventType") {
			t.Errorf("query = %v", query)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{
			"page":1,"pageSize":250,"totalRecords":2,
			"records":[
				{"id":91,"albumId":3,"artistId":2,"downloadId":"download","eventType":"grabbed","date":"2026-09-22T12:00:00Z"},
				{"id":92,"albumId":3,"artistId":2,"trackId":11,"downloadId":"download","eventType":"trackFileImported","date":"2026-09-22T12:05:00Z"}
			]
		}`))
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	identity, found, err := client.RecoverAlbumIdentity(context.Background(), "download")
	if err != nil {
		t.Fatal(err)
	}
	if !found || identity != (AlbumIdentity{AlbumID: 3, ArtistID: 2}) {
		t.Fatalf("RecoverAlbumIdentity() = (%+v, %v)", identity, found)
	}
}

func TestRecoverAlbumIdentityRejectsConflict(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{
			"page":1,"pageSize":250,"totalRecords":2,
			"records":[
				{"id":91,"albumId":3,"artistId":2,"downloadId":"download","eventType":"grabbed","date":"2026-09-22T12:00:00Z"},
				{"id":92,"albumId":4,"artistId":2,"downloadId":"download","eventType":"importFailed","date":"2026-09-22T12:05:00Z"}
			]
		}`))
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	if _, _, err := client.RecoverAlbumIdentity(context.Background(), "download"); err == nil {
		t.Fatal("RecoverAlbumIdentity() accepted conflicting history")
	}
}

func TestReadImportedTracksFiltersAndMapsHistory(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet || request.URL.Path != "/api/v1/history" {
			t.Errorf("request = %s %s", request.Method, request.URL.Path)
		}
		query := request.URL.Query()
		if query.Get("albumId") != "3" || query.Get("downloadId") != "download" ||
			query.Get("eventType") != "3" || query.Get("sortDirection") != "descending" {
			t.Errorf("query = %v", query)
		}
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"page": 1, "pageSize": 250, "totalRecords": 2,
			"records": []any{
				map[string]any{
					"id": 91, "albumId": 3, "artistId": 2, "trackId": 11,
					"downloadId": "download", "eventType": "trackFileImported",
					"date": time.Date(2026, 9, 22, 12, 0, 0, 0, time.UTC),
					"data": map[string]string{
						"droppedPath":  "/downloads/staged/01.mp3",
						"importedPath": "/music/Artist/Album/01.mp3",
					},
				},
				map[string]any{
					"id": 90, "albumId": 4, "artistId": 2, "trackId": 99,
					"downloadId": "other", "eventType": "trackFileImported",
					"date": time.Date(2026, 9, 22, 11, 0, 0, 0, time.UTC),
					"data": map[string]string{
						"droppedPath": "/other.mp3", "importedPath": "/music/other.mp3",
					},
				},
			},
		})
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	imports, err := client.ReadImportedTracks(context.Background(), 3, "download")
	if err != nil {
		t.Fatal(err)
	}
	if len(imports) != 1 || imports[0].HistoryID != 91 || imports[0].TrackID != 11 ||
		imports[0].DroppedPath != "/downloads/staged/01.mp3" {
		t.Fatalf("imports = %#v", imports)
	}
}

package lidarr

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestReadCatalogAndManualImportEvidence(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/api/v1/album/1380":
			_ = json.NewEncoder(writer).Encode(map[string]any{
				"id": 1380, "artistId": 7, "title": "The Threshingfloor",
				"monitored": true, "anyReleaseOk": false,
				"artist": map[string]any{"id": 7, "artistName": "Wovenhand"},
				"releases": []map[string]any{{
					"id": 81, "albumId": 1380, "title": "The Threshingfloor",
					"trackCount": 12, "mediumCount": 1, "format": "Vinyl", "monitored": true,
				}},
			})
		case "/api/v1/track":
			if request.URL.Query().Get("albumId") != "1380" {
				http.Error(writer, "bad album", http.StatusBadRequest)
				return
			}
			_ = json.NewEncoder(writer).Encode([]map[string]any{{
				"id": 101, "albumId": 1380, "artistId": 7,
				"absoluteTrackNumber": 1, "trackNumber": "1", "mediumNumber": 1,
				"title": "Sinking Hands", "duration": 180000,
				"hasFile": false, "trackFileId": 0,
			}})
		case "/api/v1/manualimport":
			query := request.URL.Query()
			if query.Get("folder") != "/downloads/stage" || query.Get("downloadId") != "" ||
				query.Get("artistId") != "7" || query.Get("filterExistingFiles") != "false" ||
				query.Get("replaceExistingFiles") != "true" {
				http.Error(writer, "bad query", http.StatusBadRequest)
				return
			}
			_ = json.NewEncoder(writer).Encode([]map[string]any{{
				"id": 0, "path": "/downloads/stage/01.flac", "name": "01.flac",
				"size": 1234, "albumReleaseId": 81,
				"artist": map[string]any{"id": 7}, "album": map[string]any{"id": 1380},
				"tracks":  []map[string]any{{"id": 101}},
				"quality": map[string]any{"quality": map[string]any{"id": 1, "name": "FLAC"}},
				"audioTags": map[string]any{
					"title": "Sinking Hands", "artistTitle": "Wovenhand",
					"albumTitle": "The Threshingfloor", "trackNumbers": []int{1},
					"discNumber": 1, "discCount": 1, "year": 2010,
					"duration": "00:03:00", "mediaInfo": map[string]any{"audioFormat": "FLAC"},
				},
				"rejections": []map[string]any{{"type": "temporary", "reason": "heuristic mismatch"}},
			}})
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	album, err := client.ReadAlbum(context.Background(), 1380)
	if err != nil {
		t.Fatal(err)
	}
	if album.ArtistName != "Wovenhand" || len(album.Releases) != 1 || album.Releases[0].ID != 81 {
		t.Fatalf("album = %#v", album)
	}
	tracks, err := client.ReadTracks(context.Background(), 1380)
	if err != nil {
		t.Fatal(err)
	}
	if len(tracks) != 1 || tracks[0].ID != 101 || tracks[0].HasFile {
		t.Fatalf("tracks = %#v", tracks)
	}
	imports, err := client.ReadManualImports(context.Background(), ManualImportQuery{
		Folder: "/downloads/stage", ArtistID: 7,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(imports) != 1 || imports[0].AlbumID != 1380 || imports[0].AlbumReleaseID != 81 ||
		len(imports[0].TrackIDs) != 1 || imports[0].TrackIDs[0] != 101 ||
		imports[0].DownloadID != "" || imports[0].AudioTags == nil ||
		imports[0].AudioTags.DurationMS != 180000 ||
		len(imports[0].Rejections) != 1 {
		t.Fatalf("imports = %#v", imports)
	}
}

func TestReadManualImportsRejectsResultOutsideFolder(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode([]map[string]any{{
			"id": 1, "path": "/library/Artist/Album/01.flac", "name": "01.flac", "size": 1234,
		}})
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	_, err = client.ReadManualImports(context.Background(), ManualImportQuery{
		Folder: "/downloads/stage", ArtistID: 7,
	})
	if err == nil {
		t.Fatal("manual-import result outside the requested folder was accepted")
	}
}

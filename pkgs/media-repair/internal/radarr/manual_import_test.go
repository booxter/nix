package radarr

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

const testManualImportFolder = "/downloads/Example.Movie.2026"

var testManualImportQuery = controllerManualImportQuery(42, testHistoryDownloadID, testManualImportFolder)

func TestReadManualImports(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		assertManualImportRequest(t, request, testManualImportQuery)
		data, err := os.ReadFile(filepath.Join("testdata", "manual-import.json"))
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

	imports, err := client.ReadManualImports(context.Background(), testManualImportQuery)
	if err != nil {
		t.Fatal(err)
	}
	if len(imports) != 2 {
		t.Fatalf("manual imports = %d", len(imports))
	}
	first := imports[0]
	if first.Path != "/downloads/Example.Movie.2026/Example.Movie.2026.CD1.mkv" ||
		first.RelativePath != "Example.Movie.2026.CD1.mkv" ||
		first.FolderName != "Example.Movie.2026.1080p.BluRay-GROUP" ||
		first.SizeBytes != 2_000_000_000 || first.MovieID != 42 ||
		first.DownloadID != testHistoryDownloadID || first.ReleaseGroup != "GROUP" ||
		first.IndexerFlags != 4 ||
		!reflect.DeepEqual(first.Quality, &controller.RadarrQualityModel{
			Quality: controller.RadarrQuality{
				ID: 7, Name: "Bluray-1080p", Source: "bluray",
				Resolution: 1080, Modifier: "none",
			},
			Revision: &controller.RadarrQualityRevision{
				Version: 2, Real: 1, IsRepack: true,
			},
		}) ||
		!reflect.DeepEqual(first.Languages, []controller.RadarrLanguage{{ID: 1, Name: "English"}}) ||
		len(first.Rejections) != 1 || first.Rejections[0].Code != "multiPartMovie" ||
		first.Rejections[0].Type != "permanent" ||
		first.Rejections[0].Reason != "File is suspected multi-part file, Radarr doesn't support this" {
		t.Fatalf("first manual import = %#v", first)
	}
	second := imports[1]
	if second.Quality != nil || second.ReleaseGroup != "" || second.Languages == nil ||
		len(second.Languages) != 0 || len(second.Rejections) != 1 ||
		second.Rejections[0].Code != "futureRejectionReason" ||
		second.Rejections[0].Type != "futureRejectionType" {
		t.Fatalf("nullable/future fields = %#v", second)
	}
}

func TestReadManualImportsRejectsInvalidQuery(t *testing.T) {
	t.Parallel()

	client, err := New("http://radarr.example", "key", http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	for _, query := range []controller.RadarrManualImportQuery{
		controllerManualImportQuery(0, "download", "/downloads/movie"),
		controllerManualImportQuery(42, " download ", "/downloads/movie"),
		controllerManualImportQuery(42, "download", ""),
	} {
		if _, err := client.ReadManualImports(context.Background(), query); err == nil {
			t.Fatalf("invalid query was accepted: %#v", query)
		}
	}
}

func TestReadManualImportsRejectsInconsistentResponse(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		response any
		want     string
	}{
		{name: "null response", response: nil, want: "response is null"},
		{name: "null item", response: []any{nil}, want: "item is null"},
		{
			name:     "wrong movie",
			response: []any{validManualImportResponse(43, testHistoryDownloadID, "/downloads/movie.mkv")},
			want:     "movie ID 43 does not match requested ID 42",
		},
		{
			name:     "wrong download",
			response: []any{validManualImportResponse(42, "different-download", "/downloads/movie.mkv")},
			want:     "download ID does not match request",
		},
		{
			name: "duplicate path",
			response: []any{
				validManualImportResponse(42, testHistoryDownloadID, "/downloads/movie.mkv"),
				validManualImportResponse(42, testHistoryDownloadID, "/downloads/movie.mkv"),
			},
			want: "duplicate path",
		},
		{
			name: "missing rejection reason code",
			response: func() []any {
				response := validManualImportResponse(
					42, testHistoryDownloadID, "/downloads/movie.mkv",
				)
				response["rejections"] = []any{map[string]any{
					"reason": "Unable to parse file", "type": "permanent",
				}}
				return []any{response}
			}(),
			want: "reason code is missing or invalid",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
				writeJSON(t, writer, test.response)
			}))
			defer server.Close()
			client, err := New(server.URL, "key", server.Client())
			if err != nil {
				t.Fatal(err)
			}

			_, err = client.ReadManualImports(context.Background(), testManualImportQuery)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestReadManualImportsRejectsMalformedResponse(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`[{"path":`))
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	if _, err := client.ReadManualImports(context.Background(), testManualImportQuery); err == nil {
		t.Fatal("malformed response was accepted")
	}
}

func TestReadManualImportsSanitizesHTTPError(t *testing.T) {
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

	_, err = client.ReadManualImports(context.Background(), testManualImportQuery)
	if err == nil || strings.Contains(err.Error(), responseSecret) {
		t.Fatalf("error = %v", err)
	}
	var httpError *HTTPError
	if !errors.As(err, &httpError) || httpError.StatusCode != http.StatusInternalServerError {
		t.Fatalf("HTTP error = %#v", httpError)
	}
}

func controllerManualImportQuery(movieID int64, downloadID, folder string) controller.RadarrManualImportQuery {
	return controller.RadarrManualImportQuery{
		MovieID: movieID, DownloadID: downloadID, Folder: folder,
	}
}

func validManualImportResponse(movieID int64, downloadID, path string) map[string]any {
	return map[string]any{
		"path": path, "relativePath": filepath.Base(path), "size": 1,
		"movie": map[string]any{"id": movieID}, "downloadId": downloadID,
		"languages": []any{}, "rejections": []any{},
	}
}

func assertManualImportRequest(
	t *testing.T,
	request *http.Request,
	query controller.RadarrManualImportQuery,
) {
	t.Helper()
	if request.Method != http.MethodGet || request.URL.Path != "/api/v3/manualimport" {
		t.Errorf("request = %s %s", request.Method, request.URL.Path)
	}
	if key := request.Header.Get("X-Api-Key"); key != "test-api-key" {
		t.Errorf("X-Api-Key = %q", key)
	}
	values := request.URL.Query()
	if values.Has("apikey") {
		t.Error("API key was sent in the query string")
	}
	want := map[string]string{
		"folder":              query.Folder,
		"downloadId":          query.DownloadID,
		"movieId":             strconv.FormatInt(query.MovieID, 10),
		"filterExistingFiles": "false",
	}
	for name, expected := range want {
		if actual := values.Get(name); actual != expected {
			t.Errorf("query %s = %q, want %q", name, actual, expected)
		}
	}
}

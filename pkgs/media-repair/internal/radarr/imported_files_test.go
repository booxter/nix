package radarr

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

func TestReadImportedFiles(t *testing.T) {
	t.Parallel()

	requestedPages := 0
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requestedPages++
		assertHistoryRequest(t, request, requestedPages, 42, testHistoryDownloadID)
		data, err := os.ReadFile(filepath.Join(
			"testdata",
			fmt.Sprintf("history-page-%d.json", requestedPages),
		))
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

	imports, err := client.ReadImportedFiles(context.Background(), 42, testHistoryDownloadID)
	if err != nil {
		t.Fatal(err)
	}
	if requestedPages != 2 || len(imports) != 1 {
		t.Fatalf("requested pages = %d, imports = %d", requestedPages, len(imports))
	}
	imported := imports[0]
	if imported.HistoryID != 502 || imported.MovieFileID != 90210 ||
		imported.MovieID != 42 || imported.DownloadID != testHistoryDownloadID ||
		!imported.OccurredAt.Equal(time.Date(2026, 9, 6, 17, 0, 0, 0, time.UTC)) ||
		imported.DroppedPath != "/downloads/Example.Movie.2026/Example.Movie.2026.mkv" ||
		imported.ImportedPath != "/movies/Example Movie (2026)/Example Movie.mkv" {
		t.Fatalf("imported file = %#v", imported)
	}
}

func TestReadImportedFilesRejectsInvalidEvidence(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name         string
		fileID       string
		droppedPath  string
		importedPath string
		want         string
	}{
		{
			name: "missing file ID", droppedPath: "/downloads/movie.mkv",
			importedPath: "/movies/Movie/movie.mkv", want: "movie file ID",
		},
		{
			name: "relative dropped path", fileID: "7", droppedPath: "movie.mkv",
			importedPath: "/movies/Movie/movie.mkv", want: "dropped path",
		},
		{
			name: "relative imported path", fileID: "7", droppedPath: "/downloads/movie.mkv",
			importedPath: "movie.mkv", want: "imported path",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			page := testHistoryPage{
				Page: 1, PageSize: historyPageSize, TotalRecords: 1,
				Records: []*testHistoryRecord{{
					ID: 1, MovieID: 42, DownloadID: testHistoryDownloadID,
					Date:      time.Date(2026, 9, 13, 12, 0, 0, 0, time.UTC),
					EventType: importedHistoryEvent, SourceTitle: "Movie",
					Data: map[string]string{
						"fileId": test.fileID, "droppedPath": test.droppedPath,
						"importedPath": test.importedPath,
					},
				}},
			}
			server := httptest.NewServer(historyHandler(page))
			defer server.Close()
			client, err := New(server.URL, "key", server.Client())
			if err != nil {
				t.Fatal(err)
			}
			_, err = client.ReadImportedFiles(context.Background(), 42, testHistoryDownloadID)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestImportedFileMatchUsesHistoryIDBoundary(t *testing.T) {
	t.Parallel()

	when := time.Date(2026, 9, 14, 20, 9, 25, 0, time.UTC)
	old := controller.RadarrImportedFile{
		HistoryID: 40, MovieID: 42, DownloadID: testHistoryDownloadID,
		DroppedPath: "/downloads/movie.mkv", OccurredAt: when.Add(time.Minute),
	}
	newImport := old
	newImport.HistoryID = 42
	newImport.OccurredAt = when
	mismatch := newImport
	mismatch.HistoryID = 41
	mismatch.DroppedPath = "/downloads/other.mkv"
	imports := []controller.RadarrImportedFile{newImport, old, mismatch}

	if highest := HighestImportedFileHistoryID(imports); highest != 42 {
		t.Fatalf("highest history ID = %d", highest)
	}
	found, ok := FindImportedFile(imports, ImportedFileMatch{
		MovieID: 42, DownloadID: testHistoryDownloadID,
		DroppedPath: "/downloads/movie.mkv", AfterHistoryID: 40,
	})
	if !ok || found.HistoryID != 42 {
		t.Fatalf("matched import = %#v, found = %t", found, ok)
	}
	if _, ok := FindImportedFile(imports, ImportedFileMatch{
		MovieID: 42, DownloadID: testHistoryDownloadID,
		DroppedPath: "/downloads/movie.mkv", AfterHistoryID: 42,
	}); ok {
		t.Fatal("history event at the saved boundary was accepted")
	}
}

package radarr

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

func TestRequestDownloadedMoviesScan(t *testing.T) {
	t.Parallel()

	wantRequest := map[string]any{
		"name":             "DownloadedMoviesScan",
		"path":             "/downloads/Movie.Release/radarr-repair-join.mkv",
		"downloadClientId": "ABCDEF0123456789",
		"importMode":       "copy",
	}
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/api/v3/command" {
			t.Errorf("request = %s %s", request.Method, request.URL.Path)
			http.Error(writer, "unexpected request", http.StatusBadRequest)
			return
		}
		if key := request.Header.Get("X-Api-Key"); key != "test-api-key" {
			t.Errorf("X-Api-Key = %q", key)
		}
		if request.URL.Query().Has("apikey") {
			t.Error("API key was sent in the query string")
		}
		var gotRequest any
		if err := json.NewDecoder(request.Body).Decode(&gotRequest); err != nil {
			t.Error(err)
			http.Error(writer, "invalid JSON", http.StatusBadRequest)
			return
		}
		if !reflect.DeepEqual(gotRequest, wantRequest) {
			t.Errorf("request body = %#v, want %#v", gotRequest, wantRequest)
		}
		writer.Header().Set("Content-Type", "application/json")
		writer.WriteHeader(http.StatusCreated)
		writeJSON(t, writer, map[string]any{
			"id": 92, "name": "DownloadedMoviesScan",
			"status": "queued", "result": "unknown",
		})
	}))
	defer server.Close()
	client, err := New(server.URL, "test-api-key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	command, err := client.RequestDownloadedMoviesScan(
		context.Background(),
		DownloadedMoviesScan{
			Path:       "/downloads/Movie.Release/radarr-repair-join.mkv",
			DownloadID: "ABCDEF0123456789",
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if command.ID != 92 || command.Name != "DownloadedMoviesScan" ||
		command.Status != CommandQueued || command.Result != CommandResultUnknown {
		t.Fatalf("command = %#v", command)
	}
}

func TestReadDownloadedMoviesScanCommand(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet || request.URL.Path != "/api/v3/command/92" {
			t.Errorf("request = %s %s", request.Method, request.URL.Path)
			http.Error(writer, "unexpected request", http.StatusBadRequest)
			return
		}
		writeJSON(t, writer, map[string]any{
			"id": 92, "name": "DownloadedMoviesScan",
			"message": "Completed", "status": "completed", "result": "successful",
		})
	}))
	defer server.Close()
	client, err := New(server.URL, "test-api-key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	command, err := client.ReadDownloadedMoviesScanCommand(context.Background(), 92)
	if err != nil {
		t.Fatal(err)
	}
	if command.ID != 92 || command.Name != "DownloadedMoviesScan" ||
		command.Message != "Completed" || command.Status != CommandCompleted ||
		command.Result != CommandResultSuccessful {
		t.Fatalf("command = %#v", command)
	}
}

func TestDownloadedMoviesScanRejectsInvalidInputAndWrongCommand(t *testing.T) {
	t.Parallel()

	client, err := New("http://radarr.example", "key", http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	invalid := []DownloadedMoviesScan{
		{Path: "Movie/radarr-repair-join.mkv", DownloadID: "ABCDEF0123456789"},
		{Path: "/downloads/Movie/../radarr-repair-join.mkv", DownloadID: "ABCDEF0123456789"},
		{Path: "/downloads/Movie/radarr-repair-join.mkv", DownloadID: " key "},
	}
	for _, scan := range invalid {
		if _, err := client.RequestDownloadedMoviesScan(context.Background(), scan); err == nil {
			t.Fatalf("invalid scan was accepted: %#v", scan)
		}
	}
	if _, err := client.ReadDownloadedMoviesScanCommand(context.Background(), 0); err == nil {
		t.Fatal("invalid command ID was accepted")
	}

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writeJSON(t, writer, map[string]any{
			"id": 92, "name": "ManualImport", "status": "completed",
		})
	}))
	defer server.Close()
	client, err = New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.ReadDownloadedMoviesScanCommand(context.Background(), 92)
	if err == nil || !strings.Contains(err.Error(), "instead of \"DownloadedMoviesScan\"") {
		t.Fatalf("error = %v", err)
	}
}

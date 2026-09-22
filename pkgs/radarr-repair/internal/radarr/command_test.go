package radarr

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/servarr"
)

func TestRequestManualImport(t *testing.T) {
	t.Parallel()

	authorized := testAuthorizedManualImport()
	commandRequest := controller.RadarrManualImportCommand{
		ImportMode: authorized.ImportMode,
		File:       authorized.File,
	}
	wantRequest := map[string]any{
		"name":       "ManualImport",
		"importMode": "copy",
		"files": []any{map[string]any{
			"path":         "/downloads/Example.Movie.2026/movie.mkv",
			"folderName":   "Example.Movie.2026.1080p.BluRay-GROUP",
			"releaseGroup": "GROUP",
			"indexerFlags": float64(4),
			"downloadId":   "ABCDEF0123456789",
			"movieId":      float64(42),
			"quality": map[string]any{
				"quality": map[string]any{
					"id": float64(7), "name": "Bluray-1080p", "source": "bluray",
					"resolution": float64(1080), "modifier": "none",
				},
				"revision": map[string]any{
					"version": float64(2), "real": float64(1), "isRepack": true,
				},
			},
			"languages": []any{map[string]any{"id": float64(1), "name": "English"}},
		}},
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
			"id": 81, "name": "ManualImport", "commandName": "Manual Import",
			"status": "queued", "result": "unknown",
		})
	}))
	defer server.Close()
	client, err := New(server.URL, "test-api-key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	command, err := client.RequestManualImport(context.Background(), commandRequest)
	if err != nil {
		t.Fatal(err)
	}
	if command.ID != 81 || command.Name != "ManualImport" || command.Status != servarr.CommandQueued ||
		command.Result != servarr.CommandResultUnknown {
		t.Fatalf("command = %#v", command)
	}
}

func TestReadManualImportCommand(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet || request.URL.Path != "/api/v3/command/81" {
			t.Errorf("request = %s %s", request.Method, request.URL.Path)
			http.Error(writer, "unexpected request", http.StatusBadRequest)
			return
		}
		writeJSON(t, writer, map[string]any{
			"id": 81, "name": "ManualImport", "commandName": "Manual Import",
			"message": "Imported movie.mkv", "exception": "",
			"status": "completed", "result": "successful",
		})
	}))
	defer server.Close()
	client, err := New(server.URL, "test-api-key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	command, err := client.ReadManualImportCommand(context.Background(), 81)
	if err != nil {
		t.Fatal(err)
	}
	if command.ID != 81 || command.Name != "ManualImport" ||
		command.Message != "Imported movie.mkv" || command.Exception != "" ||
		command.Status != servarr.CommandCompleted || command.Result != servarr.CommandResultSuccessful {
		t.Fatalf("command = %#v", command)
	}
}

func TestClassifyImportCommand(t *testing.T) {
	tests := []struct {
		name        string
		command     servarr.Command
		disposition servarr.ImportCommandDisposition
		wantError   bool
	}{
		{
			name: "queued",
			command: servarr.Command{
				Status: servarr.CommandQueued,
				Result: servarr.CommandResultUnknown,
			},
			disposition: servarr.ImportCommandPending,
		},
		{
			name: "completed successfully pending history confirmation",
			command: servarr.Command{
				Status: servarr.CommandCompleted,
				Result: servarr.CommandResultSuccessful,
			},
			disposition: servarr.ImportCommandPending,
		},
		{
			name: "completed unsuccessfully",
			command: servarr.Command{
				Status: servarr.CommandCompleted,
				Result: servarr.CommandResultUnsuccessful,
			},
			disposition: servarr.ImportCommandFailed,
		},
		{
			name:        "failed",
			command:     servarr.Command{Status: servarr.CommandFailed},
			disposition: servarr.ImportCommandFailed,
		},
		{
			name: "active with final result",
			command: servarr.Command{
				Status: servarr.CommandStarted,
				Result: servarr.CommandResultSuccessful,
			},
			wantError: true,
		},
		{
			name:      "unknown status",
			command:   servarr.Command{Status: "mystery"},
			wantError: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			disposition, err := servarr.ClassifyImportCommand("Radarr", test.command, true)
			if test.wantError {
				if err == nil {
					t.Fatal("expected classification to fail")
				}
				return
			}
			if err != nil {
				t.Fatalf("classify import command: %v", err)
			}
			if disposition != test.disposition {
				t.Fatalf("unexpected disposition %d", disposition)
			}
		})
	}
}

func TestManualImportCommandsRejectInvalidInputAndResponses(t *testing.T) {
	t.Parallel()

	authorized := testAuthorizedManualImport()
	authorized.ImportMode = controller.RadarrImportMode("move")
	client, err := New("http://radarr.example", "key", http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.RequestManualImport(
		context.Background(),
		controller.RadarrManualImportCommand{
			ImportMode: authorized.ImportMode,
			File:       authorized.File,
		},
	); err == nil {
		t.Fatal("incomplete authorization was accepted")
	}
	if _, err := client.ReadManualImportCommand(context.Background(), 0); err == nil {
		t.Fatal("invalid command ID was accepted")
	}

	responses := []struct {
		name     string
		response map[string]any
		want     string
	}{
		{name: "invalid ID", response: map[string]any{
			"id": 0, "name": "ManualImport", "status": "queued",
		}, want: "invalid ID"},
		{name: "different ID", response: map[string]any{
			"id": 82, "name": "ManualImport", "status": "queued",
		}, want: "requested ID 81"},
		{name: "different command", response: map[string]any{
			"id": 81, "name": "RefreshMovie", "status": "queued",
		}, want: "instead of \"ManualImport\""},
		{name: "missing status", response: map[string]any{
			"id": 81, "name": "ManualImport",
		}, want: "no status"},
	}
	for _, test := range responses {
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
			_, err = client.ReadManualImportCommand(context.Background(), 81)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func testAuthorizedManualImport() decisionpolicy.AuthorizedManualImport {
	return decisionpolicy.AuthorizedManualImport{
		CaseID:       "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		CapabilityID: "capability:manual",
		FileID:       "file:movie",
		ExpectedFingerprint: controller.FileFingerprint{
			Device: 1, Inode: 2, SizeBytes: 3, MTimeNS: 4,
		},
		ImportMode: controller.RadarrImportModeCopy,
		File: controller.RadarrManualImportCommandFile{
			Path:       "/downloads/Example.Movie.2026/movie.mkv",
			FolderName: "Example.Movie.2026.1080p.BluRay-GROUP",
			Quality: controller.RadarrQualityModel{
				Quality: controller.RadarrQuality{
					ID: 7, Name: "Bluray-1080p", Source: "bluray",
					Resolution: 1080, Modifier: "none",
				},
				Revision: &controller.RadarrQualityRevision{Version: 2, Real: 1, IsRepack: true},
			},
			Languages:    []controller.RadarrLanguage{{ID: 1, Name: "English"}},
			ReleaseGroup: "GROUP",
			IndexerFlags: 4,
			DownloadID:   "ABCDEF0123456789",
			MovieID:      42,
		},
		ProbeDurationMS: 7_200_000,
	}
}

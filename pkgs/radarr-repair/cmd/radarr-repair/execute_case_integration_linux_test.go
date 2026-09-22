//go:build linux

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/executioncheck"
	"github.com/booxter/nix-config/radarr-repair/internal/ffprobe"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
	workerprobe "github.com/booxter/nix-config/radarr-repair/worker/probe"
	workerserver "github.com/booxter/nix-config/radarr-repair/worker/server"
)

const (
	integrationAPIKey     = "integration-api-key"
	integrationDownloadID = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
	integrationMovieID    = int64(42)
)

func TestExecuteStoredCaseImportsAuthorizedFile(t *testing.T) {
	fixture := newManualWorkflowFixture(t)
	assembly, decision := fixture.storePlannedCase(t)

	result, err := executeStoredCase(context.Background(), fixture.executeConfig(assembly.Request.CaseID))
	if err != nil {
		t.Fatal(err)
	}
	if result.ManualImport == nil || result.ManualImport.State != casestore.ManualImportImported {
		t.Fatalf("execution result = %#v", result)
	}
	if result.Resumed || !result.Check.Accepted() {
		t.Fatalf("execution was not freshly accepted: %#v", result)
	}

	request, writes, polls := fixture.radarr.executionObservation()
	if writes != 1 || polls == 0 {
		t.Fatalf("Radarr manual-import writes = %d, command polls = %d", writes, polls)
	}
	assertManualImportCommand(t, request, assembly, decision)

	store, err := casestore.New(fixture.stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	stored, found, err := store.GetManualImportExecution(assembly.Request.CaseID)
	if err != nil {
		t.Fatal(err)
	}
	if !found || stored.State != casestore.ManualImportImported || stored.Confirmation == nil {
		t.Fatalf("stored execution = %#v, found = %t", stored, found)
	}
	confirmation := stored.Confirmation
	if confirmation.HistoryID != 502 || confirmation.MovieFileID != 90210 ||
		confirmation.MovieID != integrationMovieID || confirmation.DownloadID != integrationDownloadID ||
		confirmation.DroppedPath != fixture.mediaPath ||
		confirmation.ImportedPath != "/movies/Example Movie (2026)/Example Movie.mkv" {
		t.Fatalf("stored confirmation = %#v", confirmation)
	}
}

func TestExecuteStoredCaseRejectsChangedInputBeforeRadarrWrite(t *testing.T) {
	fixture := newManualWorkflowFixture(t)
	assembly, _ := fixture.storePlannedCase(t)
	changed := time.Now().Add(time.Minute)
	if err := os.Chtimes(fixture.mediaPath, changed, changed); err != nil {
		t.Fatal(err)
	}

	result, err := executeStoredCase(context.Background(), fixture.executeConfig(assembly.Request.CaseID))
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Check.Rejections) != 1 ||
		result.Check.Rejections[0].Reason != executioncheck.CaseChanged {
		t.Fatalf("execution result = %#v", result)
	}
	if _, writes, _ := fixture.radarr.executionObservation(); writes != 0 {
		t.Fatalf("Radarr received %d manual-import writes", writes)
	}

	store, err := casestore.New(fixture.stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if stored, found, err := store.GetManualImportExecution(assembly.Request.CaseID); err != nil {
		t.Fatal(err)
	} else if found {
		t.Fatalf("unexpected stored execution = %#v", stored)
	}
}

type manualWorkflowFixture struct {
	radarr         *fakeRadarrServer
	radarrServer   *httptest.Server
	transmission   *httptest.Server
	apiKeyPath     string
	downloadRoot   string
	mediaPath      string
	workerSocket   string
	stateDirectory string
}

func newManualWorkflowFixture(t *testing.T) *manualWorkflowFixture {
	t.Helper()
	root := t.TempDir()
	downloadDirectory := filepath.Join(root, "downloads")
	downloadRoot := filepath.Join(downloadDirectory, "Example.Movie.2026")
	if err := os.MkdirAll(downloadRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	mediaPath := filepath.Join(downloadRoot, "Example.Movie.2026.mkv")
	makeIntegrationMedia(t, mediaPath)
	mediaInfo, err := os.Stat(mediaPath)
	if err != nil {
		t.Fatal(err)
	}

	radarr := &fakeRadarrServer{
		downloadRoot: downloadRoot,
		mediaPath:    mediaPath,
		mediaSize:    mediaInfo.Size(),
	}
	radarrServer := httptest.NewServer(radarr)
	t.Cleanup(radarrServer.Close)
	transmission := httptest.NewServer(fakeTransmissionHandler(
		downloadDirectory,
		mediaInfo.Size(),
	))
	t.Cleanup(transmission.Close)
	apiKeyPath := filepath.Join(root, "radarr-api-key")
	if err := os.WriteFile(apiKeyPath, []byte(integrationAPIKey+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	workerSocket := filepath.Join(root, "worker.sock")
	startProbeWorker(t, downloadDirectory, workerSocket)

	return &manualWorkflowFixture{
		radarr:         radarr,
		radarrServer:   radarrServer,
		transmission:   transmission,
		apiKeyPath:     apiKeyPath,
		downloadRoot:   downloadRoot,
		mediaPath:      mediaPath,
		workerSocket:   workerSocket,
		stateDirectory: filepath.Join(root, "state"),
	}
}

func (fixture *manualWorkflowFixture) inspectionConfig() inspectConfig {
	return inspectConfig{
		RadarrURL:         fixture.radarrServer.URL,
		RadarrAPIKeyFile:  fixture.apiKeyPath,
		TransmissionURL:   fixture.transmission.URL,
		WorkerSocket:      fixture.workerSocket,
		WorkerRoots:       map[string]string{"root:downloads": filepath.Dir(fixture.downloadRoot)},
		QueueID:           101,
		Timeout:           10 * time.Second,
		CollectionTimeout: 30 * time.Second,
	}
}

func (fixture *manualWorkflowFixture) executeConfig(caseID string) executeCaseConfig {
	inspection := fixture.inspectionConfig()
	return executeCaseConfig{
		RadarrURL:         inspection.RadarrURL,
		RadarrAPIKeyFile:  inspection.RadarrAPIKeyFile,
		TransmissionURL:   inspection.TransmissionURL,
		WorkerSocket:      inspection.WorkerSocket,
		WorkerRoots:       inspection.WorkerRoots,
		StateDirectory:    fixture.stateDirectory,
		CaseID:            caseID,
		RequestTimeout:    inspection.Timeout,
		CollectionTimeout: inspection.CollectionTimeout,
		Stabilization:     time.Millisecond,
		PollInterval:      time.Millisecond,
	}
}

func (fixture *manualWorkflowFixture) storePlannedCase(
	t *testing.T,
) (assembly casebuilder.Assembly, decision contracts.RepairDecisionV3) {
	t.Helper()
	observed, err := inspectCase(context.Background(), fixture.inspectionConfig())
	if err != nil {
		t.Fatal(err)
	}
	var selected *contracts.Capability
	for index := range observed.Request.Capabilities {
		capability := &observed.Request.Capabilities[index]
		if capability.Action == contracts.CapabilityActionManualImportFile {
			selected = capability
			break
		}
	}
	if selected == nil || selected.FileID == nil {
		t.Fatalf("case has no manual-import capability: %#v", observed.Request.Capabilities)
	}
	decision = contracts.RepairDecisionV3{
		Kind: contracts.ActionManualImportFile,
		ManualImportFile: &contracts.ManualImportFileDecision{
			Action:        contracts.ManualImportFileDecisionAction(contracts.ActionManualImportFile),
			CaseID:        observed.Request.CaseID,
			CapabilityID:  selected.CapabilityID,
			EvidenceRefs:  []string{*selected.FileID},
			Explanation:   "Radarr can import this complete movie file with its retained metadata.",
			FileID:        *selected.FileID,
			SchemaVersion: contracts.RadarrRepairV3,
		},
	}
	store, err := casestore.New(fixture.stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.PutAssembly(observed); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.PutPlanningDecision(observed.Request.CaseID, decision, time.Now()); err != nil {
		t.Fatal(err)
	}
	return observed, decision
}

type fakeRadarrServer struct {
	mutex          sync.Mutex
	downloadRoot   string
	mediaPath      string
	mediaSize      int64
	commandPosted  bool
	commandPolled  bool
	commandRequest manualImportCommandObservation
	writes         int
	polls          int
}

type manualImportCommandObservation struct {
	Name       string `json:"name"`
	ImportMode string `json:"importMode"`
	Files      []struct {
		Path         string `json:"path"`
		FolderName   string `json:"folderName"`
		ReleaseGroup string `json:"releaseGroup"`
		IndexerFlags int64  `json:"indexerFlags"`
		DownloadID   string `json:"downloadId"`
		MovieID      int64  `json:"movieId"`
		Quality      struct {
			Quality struct {
				ID         int64  `json:"id"`
				Name       string `json:"name"`
				Source     string `json:"source"`
				Resolution int    `json:"resolution"`
				Modifier   string `json:"modifier"`
			} `json:"quality"`
			Revision *struct {
				Version  int64 `json:"version"`
				Real     int64 `json:"real"`
				IsRepack bool  `json:"isRepack"`
			} `json:"revision"`
		} `json:"quality"`
		Languages []struct {
			ID   int64  `json:"id"`
			Name string `json:"name"`
		} `json:"languages"`
	} `json:"files"`
}

func (server *fakeRadarrServer) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if request.Header.Get("X-Api-Key") != integrationAPIKey {
		http.Error(writer, "missing API key", http.StatusUnauthorized)
		return
	}
	switch {
	case request.Method == http.MethodGet && request.URL.Path == "/api/v3/queue":
		server.writeQueue(writer)
	case request.Method == http.MethodGet && request.URL.Path == "/api/v3/movie/42":
		writeIntegrationJSON(writer, map[string]any{
			"id": integrationMovieID, "tmdbId": 123456, "title": "Example Movie",
			"originalTitle": "Example Movie", "alternateTitles": []any{},
			"year": 2026, "runtime": 0,
		})
	case request.Method == http.MethodGet && request.URL.Path == "/api/v3/history":
		server.writeHistory(writer)
	case request.Method == http.MethodGet && request.URL.Path == "/api/v3/manualimport":
		server.writeManualImport(writer)
	case request.Method == http.MethodPost && request.URL.Path == "/api/v3/command":
		server.acceptManualImport(writer, request)
	case request.Method == http.MethodGet && request.URL.Path == "/api/v3/command/81":
		server.completeCommand(writer)
	default:
		http.Error(writer, "unexpected request", http.StatusNotFound)
	}
}

func (server *fakeRadarrServer) writeQueue(writer http.ResponseWriter) {
	writeIntegrationJSON(writer, map[string]any{
		"page": 1, "pageSize": 250, "sortKey": "added", "sortDirection": "ascending",
		"totalRecords": 1,
		"records": []any{map[string]any{
			"id": 101, "movieId": integrationMovieID, "title": "Example.Movie.2026",
			"size": server.mediaSize, "sizeleft": 0, "status": "completed",
			"trackedDownloadStatus": "warning", "trackedDownloadState": "importBlocked",
			"statusMessages": []any{map[string]any{
				"title": "Example.Movie.2026", "messages": []string{"Unable to parse file"},
			}},
			"downloadId": integrationDownloadID, "protocol": "torrent",
			"downloadClient": "Transmission", "outputPath": server.downloadRoot,
		}},
	})
}

func (server *fakeRadarrServer) writeHistory(writer http.ResponseWriter) {
	server.mutex.Lock()
	includeImport := server.commandPosted && server.commandPolled
	server.mutex.Unlock()
	records := []any{map[string]any{
		"id": 501, "movieId": integrationMovieID, "downloadId": integrationDownloadID,
		"date": "2026-09-01T12:00:00Z", "eventType": "grabbed",
		"sourceTitle": "Example.Movie.2026.1080p.BluRay",
		"quality":     integrationQuality(),
		"languages":   []any{map[string]any{"id": 1, "name": "English"}},
		"data":        map[string]any{},
	}}
	if includeImport {
		records = append(records, map[string]any{
			"id": 502, "movieId": integrationMovieID, "downloadId": integrationDownloadID,
			"date": time.Now().Add(time.Minute).UTC(), "eventType": "downloadFolderImported",
			"sourceTitle": "Example.Movie.2026.1080p.BluRay",
			"quality":     integrationQuality(), "languages": []any{},
			"data": map[string]any{
				"fileId": "90210", "droppedPath": server.mediaPath,
				"importedPath": "/movies/Example Movie (2026)/Example Movie.mkv",
			},
		})
	}
	writeIntegrationJSON(writer, map[string]any{
		"page": 1, "pageSize": 250, "sortKey": "date", "sortDirection": "ascending",
		"totalRecords": len(records), "records": records,
	})
}

func (server *fakeRadarrServer) writeManualImport(writer http.ResponseWriter) {
	writeIntegrationJSON(writer, []any{map[string]any{
		"id": 1001, "path": server.mediaPath, "relativePath": filepath.Base(server.mediaPath),
		"folderName": "Example.Movie.2026.1080p.BluRay-GROUP", "size": server.mediaSize,
		"movie":      map[string]any{"id": integrationMovieID, "title": "Example Movie"},
		"downloadId": integrationDownloadID, "quality": integrationQuality(),
		"languages":    []any{map[string]any{"id": 1, "name": "English"}},
		"releaseGroup": "GROUP", "indexerFlags": 4, "rejections": []any{},
	}})
}

func (server *fakeRadarrServer) acceptManualImport(
	writer http.ResponseWriter,
	request *http.Request,
) {
	var observed manualImportCommandObservation
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&observed); err != nil {
		http.Error(writer, "invalid command", http.StatusBadRequest)
		return
	}
	server.mutex.Lock()
	server.commandPosted = true
	server.commandRequest = observed
	server.writes++
	server.mutex.Unlock()
	writer.WriteHeader(http.StatusCreated)
	writeIntegrationJSON(writer, map[string]any{
		"id": 81, "name": "ManualImport", "status": "queued", "result": "unknown",
	})
}

func (server *fakeRadarrServer) completeCommand(writer http.ResponseWriter) {
	server.mutex.Lock()
	server.commandPolled = true
	server.polls++
	server.mutex.Unlock()
	writeIntegrationJSON(writer, map[string]any{
		"id": 81, "name": "ManualImport", "status": "completed", "result": "successful",
	})
}

func (server *fakeRadarrServer) executionObservation() (
	manualImportCommandObservation,
	int,
	int,
) {
	server.mutex.Lock()
	defer server.mutex.Unlock()
	return server.commandRequest, server.writes, server.polls
}

func integrationQuality() map[string]any {
	return map[string]any{
		"quality": map[string]any{
			"id": 7, "name": "Bluray-1080p", "source": "bluray",
			"resolution": 1080, "modifier": "none",
		},
		"revision": map[string]any{"version": 1, "real": 0, "isRepack": false},
	}
}

func fakeTransmissionHandler(downloadDirectory string, mediaSize int64) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var envelope struct {
			ID     uint64 `json:"id"`
			Method string `json:"method"`
		}
		if request.Method != http.MethodPost ||
			json.NewDecoder(request.Body).Decode(&envelope) != nil ||
			envelope.Method != "torrent_get" {
			http.Error(writer, "unexpected request", http.StatusBadRequest)
			return
		}
		writeIntegrationJSON(writer, map[string]any{
			"jsonrpc": "2.0", "id": envelope.ID,
			"result": map[string]any{"torrents": []any{map[string]any{
				"hash_string": "abcdef0123456789abcdef0123456789abcdef01",
				"name":        "Example.Movie.2026", "status": 6, "percent_done": 1.0,
				"left_until_done": 0, "is_finished": true,
				"download_dir": downloadDirectory, "labels": []string{"radarr"},
				"date_created": 1788600000, "added_date": 1788703200,
				"done_date": 1788706800, "total_size": mediaSize,
				"files": []any{map[string]any{
					"name":   "Example.Movie.2026/Example.Movie.2026.mkv",
					"length": mediaSize, "bytes_completed": mediaSize,
				}},
				"file_stats": []any{map[string]any{
					"bytes_completed": mediaSize, "wanted": true, "priority": 0,
				}},
			}},
			},
		})
	})
}

func startProbeWorker(t *testing.T, rootPath, socketPath string) {
	t.Helper()
	roots, err := mediafile.NewRootSet(map[string]string{"root:downloads": rootPath})
	if err != nil {
		t.Fatal(err)
	}
	probeRunner, err := ffprobe.NewRunner(requiredIntegrationExecutable(t, "RADARR_REPAIR_TEST_FFPROBE"), 10*time.Second)
	if err != nil {
		_ = roots.Close()
		t.Fatal(err)
	}
	executor, err := workerprobe.NewExecutor(roots, probeRunner)
	if err != nil {
		_ = roots.Close()
		t.Fatal(err)
	}
	handler, err := workerserver.NewHandler(executor, 10*time.Second, 1)
	if err != nil {
		_ = roots.Close()
		t.Fatal(err)
	}
	listener, err := workerserver.ListenUnix(socketPath)
	if err != nil {
		_ = roots.Close()
		t.Fatal(err)
	}
	server := &http.Server{Handler: handler, ReadHeaderTimeout: time.Second}
	stopped := make(chan error, 1)
	go func() { stopped <- server.Serve(listener) }()
	t.Cleanup(func() {
		if err := server.Close(); err != nil {
			t.Error(err)
		}
		if err := <-stopped; err != nil && err != http.ErrServerClosed {
			t.Error(err)
		}
		if err := roots.Close(); err != nil {
			t.Error(err)
		}
	})
}

func makeIntegrationMedia(t *testing.T, path string) {
	t.Helper()
	command := exec.Command(
		requiredIntegrationExecutable(t, "RADARR_REPAIR_TEST_FFMPEG"),
		"-hide_banner", "-loglevel", "error", "-nostdin",
		"-f", "lavfi", "-i", "color=c=red:s=16x16:r=25:d=0.2",
		"-c:v", "ffv1", "-y", path,
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("create test media: %v: %s", err, output)
	}
}

func requiredIntegrationExecutable(t *testing.T, name string) string {
	t.Helper()
	path := os.Getenv(name)
	if path == "" {
		t.Fatalf("%s is not set", name)
	}
	return path
}

func writeIntegrationJSON(writer http.ResponseWriter, value any) {
	writer.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(writer).Encode(value); err != nil {
		panic(fmt.Sprintf("encode integration response: %v", err))
	}
}

func assertManualImportCommand(
	t *testing.T,
	request manualImportCommandObservation,
	assembly casebuilder.Assembly,
	decision contracts.RepairDecisionV3,
) {
	t.Helper()
	if request.Name != "ManualImport" || request.ImportMode != "copy" || len(request.Files) != 1 {
		t.Fatalf("manual-import request = %#v", request)
	}
	if decision.ManualImportFile == nil {
		t.Fatal("manual-import decision is missing")
	}
	binding, found := assembly.LocalSnapshot.ManualImportBindings[decision.ManualImportFile.CapabilityID]
	if !found {
		t.Fatal("manual-import binding is missing")
	}
	file := request.Files[0]
	if file.Path != binding.File.Path || file.FolderName != binding.File.FolderName ||
		file.ReleaseGroup != binding.File.ReleaseGroup || file.IndexerFlags != binding.File.IndexerFlags ||
		file.DownloadID != binding.File.DownloadID || file.MovieID != binding.File.MovieID ||
		file.Quality.Quality.ID != binding.File.Quality.Quality.ID ||
		file.Quality.Quality.Name != binding.File.Quality.Quality.Name ||
		file.Quality.Quality.Source != binding.File.Quality.Quality.Source ||
		file.Quality.Quality.Resolution != binding.File.Quality.Quality.Resolution ||
		file.Quality.Quality.Modifier != binding.File.Quality.Quality.Modifier ||
		file.Quality.Revision == nil || binding.File.Quality.Revision == nil ||
		file.Quality.Revision.Version != binding.File.Quality.Revision.Version ||
		file.Quality.Revision.Real != binding.File.Quality.Revision.Real ||
		file.Quality.Revision.IsRepack != binding.File.Quality.Revision.IsRepack ||
		len(file.Languages) != 1 || file.Languages[0].ID != binding.File.Languages[0].ID ||
		file.Languages[0].Name != binding.File.Languages[0].Name {
		t.Fatalf("manual-import file = %#v", file)
	}
}

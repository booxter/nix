//go:build linux

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/ffprobe"
)

func TestExecuteStoredCaseJoinsAndImportsAuthorizedParts(t *testing.T) {
	root := t.TempDir()
	downloadDirectory := filepath.Join(root, "downloads")
	downloadRoot := filepath.Join(downloadDirectory, "Example.Movie.2026")
	if err := os.MkdirAll(downloadRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	partPaths := []string{
		filepath.Join(downloadRoot, "Example.Movie.2026.CD1.mkv"),
		filepath.Join(downloadRoot, "Example.Movie.2026.CD2.mkv"),
	}
	parts := make([]joinTorrentFile, len(partPaths))
	sourceDigests := make([][sha256.Size]byte, len(partPaths))
	for index, path := range partPaths {
		makeIntegrationMedia(t, path)
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		sourceDigests[index] = sha256.Sum256(data)
		parts[index] = joinTorrentFile{
			relativePath: filepath.Join("Example.Movie.2026", filepath.Base(path)),
			sizeBytes:    int64(len(data)),
		}
	}

	workerSocket := filepath.Join(root, "worker.sock")
	startPackagedWorker(t, downloadDirectory, filepath.Join(root, "worker-state"), workerSocket)
	radarr := &joinRadarrServer{
		downloadRoot: downloadRoot,
		totalSize:    parts[0].sizeBytes + parts[1].sizeBytes,
	}
	radarrHTTP := httptest.NewServer(radarr)
	t.Cleanup(radarrHTTP.Close)
	transmissionHTTP := httptest.NewServer(joinTransmissionHandler(downloadDirectory, parts))
	t.Cleanup(transmissionHTTP.Close)
	apiKeyPath := filepath.Join(root, "radarr-api-key")
	if err := os.WriteFile(apiKeyPath, []byte(integrationAPIKey+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	stateDirectory := filepath.Join(root, "controller-state")
	inspectionConfig := inspectConfig{
		RadarrURL:         radarrHTTP.URL,
		RadarrAPIKeyFile:  apiKeyPath,
		TransmissionURL:   transmissionHTTP.URL,
		WorkerSocket:      workerSocket,
		WorkerRoots:       map[string]string{"root:downloads": downloadDirectory},
		QueueID:           101,
		Timeout:           10 * time.Second,
		CollectionTimeout: 30 * time.Second,
	}
	assembly, err := inspectCase(context.Background(), inspectionConfig)
	if err != nil {
		t.Fatal(err)
	}
	capability := joinCapability(t, assembly.Request.Capabilities)
	decision := contracts.RepairDecisionV3{
		Kind: contracts.ActionJoinParts,
		JoinParts: &contracts.JoinDecision{
			Action:         contracts.JoinDecisionAction(contracts.ActionJoinParts),
			CapabilityID:   capability.CapabilityID,
			CaseID:         assembly.Request.CaseID,
			EvidenceRefs:   append([]string(nil), capability.CandidateFileIDS...),
			Explanation:    "The two numbered files are compatible consecutive movie parts.",
			OrderedFileIDS: append([]string(nil), capability.CandidateFileIDS...),
			SchemaVersion:  contracts.RadarrRepairV3,
		},
	}
	store, err := casestore.New(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.PutAssembly(assembly); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.PutPlanningDecision(
		assembly.Request.CaseID,
		decision,
		time.Now(),
	); err != nil {
		t.Fatal(err)
	}

	result, err := executeStoredCase(context.Background(), executeCaseConfig{
		RadarrURL:         inspectionConfig.RadarrURL,
		RadarrAPIKeyFile:  inspectionConfig.RadarrAPIKeyFile,
		TransmissionURL:   inspectionConfig.TransmissionURL,
		WorkerSocket:      inspectionConfig.WorkerSocket,
		WorkerRoots:       inspectionConfig.WorkerRoots,
		StateDirectory:    stateDirectory,
		CaseID:            assembly.Request.CaseID,
		RequestTimeout:    inspectionConfig.Timeout,
		CollectionTimeout: inspectionConfig.CollectionTimeout,
		Stabilization:     time.Millisecond,
		PollInterval:      time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Join == nil || result.Join.State != casestore.JoinImported ||
		result.Join.Published == nil || result.Join.Confirmation == nil {
		t.Fatalf("execution result = %#v", result)
	}
	if result.Resumed || !result.Check.Accepted() {
		t.Fatalf("execution was not freshly accepted: %#v", result)
	}

	publishedPath := filepath.Join(
		downloadDirectory,
		filepath.Join(result.Join.Published.PathComponents...),
	)
	if filepath.Dir(publishedPath) != downloadRoot {
		t.Fatalf("published path = %q", publishedPath)
	}
	assertJoinedDuration(t, publishedPath, result.Join.Authorization)
	for index, path := range partPaths {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if sha256.Sum256(data) != sourceDigests[index] {
			t.Fatalf("source part %q was modified", path)
		}
	}

	importRequest, writes, polls := radarr.executionObservation()
	if writes != 1 || polls == 0 {
		t.Fatalf("Radarr importRequest writes = %d, command polls = %d", writes, polls)
	}
	if importRequest.Name != "ManualImport" || importRequest.ImportMode != "copy" ||
		len(importRequest.Files) != 1 || importRequest.Files[0].Path != publishedPath ||
		importRequest.Files[0].DownloadID != integrationDownloadID ||
		importRequest.Files[0].MovieID != integrationMovieID ||
		importRequest.Files[0].Quality.Quality.Name != "Bluray-1080p" ||
		len(importRequest.Files[0].Languages) != 1 ||
		importRequest.Files[0].Languages[0].Name != "English" {
		t.Fatalf("manual import request = %#v", importRequest)
	}
	stored, found, err := store.GetJoinExecution(assembly.Request.CaseID)
	if err != nil {
		t.Fatal(err)
	}
	if !found || stored.State != casestore.JoinImported || stored.Confirmation == nil ||
		stored.Confirmation.DroppedPath != publishedPath ||
		stored.Confirmation.ImportedPath != "/movies/Example Movie (2026)/Example Movie.mkv" {
		t.Fatalf("stored join execution = %#v, found = %t", stored, found)
	}
}

func joinCapability(t *testing.T, capabilities []contracts.Capability) contracts.Capability {
	t.Helper()
	for _, capability := range capabilities {
		if capability.Action == contracts.CapabilityActionJoinParts {
			if len(capability.CandidateFileIDS) != 2 {
				t.Fatalf("join candidates = %#v", capability.CandidateFileIDS)
			}
			return capability
		}
	}
	t.Fatalf("case has no join capability: %#v", capabilities)
	return contracts.Capability{}
}

func assertJoinedDuration(
	t *testing.T,
	path string,
	authorized decisionpolicy.AuthorizedJoin,
) {
	t.Helper()
	media, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer media.Close()
	runner, err := ffprobe.NewRunner(
		requiredIntegrationExecutable(t, "RADARR_REPAIR_TEST_FFPROBE"),
		10*time.Second,
	)
	if err != nil {
		t.Fatal(err)
	}
	evidence, err := runner.ProbeFile(context.Background(), media)
	if err != nil {
		t.Fatal(err)
	}
	duration := controller.AssessProbeDuration(evidence)
	if duration.Conflict || duration.EffectiveMS == nil {
		t.Fatalf("joined duration = %#v", duration)
	}
	difference := *duration.EffectiveMS - authorized.ExpectedDurationMS
	if difference < 0 {
		difference = -difference
	}
	if difference > authorized.DurationToleranceMS {
		t.Fatalf(
			"joined duration = %d ms, expected %d ± %d ms",
			*duration.EffectiveMS,
			authorized.ExpectedDurationMS,
			authorized.DurationToleranceMS,
		)
	}
}

type joinTorrentFile struct {
	relativePath string
	sizeBytes    int64
}

type joinedManualImportObservation struct {
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

type joinRadarrServer struct {
	mutex         sync.Mutex
	downloadRoot  string
	totalSize     int64
	importRequest joinedManualImportObservation
	commandPosted bool
	commandPolled bool
	writes        int
	polls         int
}

func (server *joinRadarrServer) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
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
		writeIntegrationJSON(writer, []any{})
	case request.Method == http.MethodPost && request.URL.Path == "/api/v3/command":
		server.acceptImport(writer, request)
	case request.Method == http.MethodGet && request.URL.Path == "/api/v3/command/92":
		server.completeCommand(writer)
	default:
		http.Error(writer, "unexpected request", http.StatusNotFound)
	}
}

func (server *joinRadarrServer) writeQueue(writer http.ResponseWriter) {
	writeIntegrationJSON(writer, map[string]any{
		"page": 1, "pageSize": 250, "sortKey": "added", "sortDirection": "ascending",
		"totalRecords": 1,
		"records": []any{map[string]any{
			"id": 101, "movieId": integrationMovieID, "title": "Example.Movie.2026",
			"size": server.totalSize, "sizeleft": 0, "status": "completed",
			"trackedDownloadStatus": "warning", "trackedDownloadState": "importBlocked",
			"statusMessages": []any{map[string]any{
				"title":    "Example.Movie.2026",
				"messages": []string{"File is suspected multi-part file, Radarr doesn't support this"},
			}},
			"downloadId": integrationDownloadID, "protocol": "torrent",
			"downloadClient": "Transmission", "outputPath": server.downloadRoot,
		}},
	})
}

func (server *joinRadarrServer) writeHistory(writer http.ResponseWriter) {
	server.mutex.Lock()
	includeImport := server.commandPosted && server.commandPolled
	importRequestPath := ""
	if len(server.importRequest.Files) == 1 {
		importRequestPath = server.importRequest.Files[0].Path
	}
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
				"fileId": "90210", "droppedPath": importRequestPath,
				"importedPath": "/movies/Example Movie (2026)/Example Movie.mkv",
			},
		})
	}
	writeIntegrationJSON(writer, map[string]any{
		"page": 1, "pageSize": 250, "sortKey": "date", "sortDirection": "ascending",
		"totalRecords": len(records), "records": records,
	})
}

func (server *joinRadarrServer) acceptImport(writer http.ResponseWriter, request *http.Request) {
	var observed joinedManualImportObservation
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&observed); err != nil {
		http.Error(writer, "invalid command", http.StatusBadRequest)
		return
	}
	server.mutex.Lock()
	server.importRequest = observed
	server.commandPosted = true
	server.writes++
	server.mutex.Unlock()
	writer.WriteHeader(http.StatusCreated)
	writeIntegrationJSON(writer, map[string]any{
		"id": 92, "name": "ManualImport", "status": "queued", "result": "unknown",
	})
}

func (server *joinRadarrServer) completeCommand(writer http.ResponseWriter) {
	server.mutex.Lock()
	server.commandPolled = true
	server.polls++
	server.mutex.Unlock()
	writeIntegrationJSON(writer, map[string]any{
		"id": 92, "name": "ManualImport", "status": "completed", "result": "successful",
	})
}

func (server *joinRadarrServer) executionObservation() (
	joinedManualImportObservation,
	int,
	int,
) {
	server.mutex.Lock()
	defer server.mutex.Unlock()
	return server.importRequest, server.writes, server.polls
}

func joinTransmissionHandler(downloadDirectory string, files []joinTorrentFile) http.Handler {
	totalSize := int64(0)
	fileResponses := make([]any, len(files))
	fileStats := make([]any, len(files))
	for index, file := range files {
		totalSize += file.sizeBytes
		fileResponses[index] = map[string]any{
			"name": file.relativePath, "length": file.sizeBytes,
			"bytes_completed": file.sizeBytes,
		}
		fileStats[index] = map[string]any{
			"bytes_completed": file.sizeBytes, "wanted": true, "priority": 0,
		}
	}
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
				"done_date": 1788706800, "total_size": totalSize,
				"files": fileResponses, "file_stats": fileStats,
			}},
			},
		})
	})
}

func startPackagedWorker(t *testing.T, rootPath, stateDirectory, socketPath string) {
	t.Helper()
	command := exec.Command(
		requiredIntegrationExecutable(t, "RADARR_REPAIR_TEST_WORKER"),
		"--socket", socketPath,
		"--state-directory", stateDirectory,
		"--root", "root:downloads="+rootPath,
		"--timeout", "10s",
		"--join-timeout", "10s",
		"--max-concurrent", "1",
	)
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	waitForPackagedWorker(t, command, socketPath, done, &stderr)
	t.Cleanup(func() {
		if err := command.Process.Signal(syscall.SIGTERM); err != nil &&
			!errors.Is(err, os.ErrProcessDone) {
			t.Error(err)
		}
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("worker stopped with error: %v: %s", err, stderr.String())
			}
		case <-time.After(10 * time.Second):
			_ = command.Process.Kill()
			t.Error("worker did not stop")
		}
	})
}

func waitForPackagedWorker(
	t *testing.T,
	command *exec.Cmd,
	socketPath string,
	done <-chan error,
	stderr *bytes.Buffer,
) {
	t.Helper()
	timer := time.NewTimer(10 * time.Second)
	defer timer.Stop()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case err := <-done:
			t.Fatalf("worker exited before serving: %v: %s", err, stderr.String())
		case <-ticker.C:
			if info, err := os.Lstat(socketPath); err == nil && info.Mode()&os.ModeSocket != 0 {
				return
			}
		case <-timer.C:
			_ = command.Process.Kill()
			<-done
			t.Fatalf("worker socket was not created: %s", stderr.String())
		}
	}
}

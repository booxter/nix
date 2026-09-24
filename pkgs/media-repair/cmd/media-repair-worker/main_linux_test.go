package main

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	workerserver "github.com/booxter/nix-config/media-repair/worker/server"
	"golang.org/x/sys/unix"
)

func TestWorkerServesRealProbeOverUnixSocket(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	mediaDirectory := filepath.Join(rootPath, "Movie")
	if err := os.Mkdir(mediaDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	mediaPath := filepath.Join(mediaDirectory, "movie.mkv")
	makeMedia(t, mediaPath, "red")
	worker := startTestWorker(t, rootPath)

	probeRequest := workercontracts.ProbeRequestV1{
		ExpectedFingerprint: pathFingerprint(t, mediaPath),
		Operation:           workercontracts.ProbeV1,
		PathComponents:      []string{"Movie", "movie.mkv"},
		RequestID:           "request:integration",
		RootID:              "root:downloads",
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	}
	requestData, err := workercontracts.EncodeProbeRequest(probeRequest)
	if err != nil {
		t.Fatal(err)
	}
	status, responseData := postWorker(t, worker.client, "/v1/probe", requestData)
	response, err := workercontracts.DecodeProbeResponse(responseData)
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusOK || response.Success == nil ||
		response.RequestID() != probeRequest.RequestID ||
		len(response.Success.Evidence.Streams) != 1 {
		t.Fatalf("HTTP status = %d, response = %#v", status, response)
	}
}

func TestWorkerPublishesRealJoinOverUnixSocket(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	mediaDirectory := filepath.Join(rootPath, "Movie")
	if err := os.Mkdir(mediaDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	firstPath := filepath.Join(mediaDirectory, "first.mkv")
	secondPath := filepath.Join(mediaDirectory, "second.mkv")
	makeMedia(t, firstPath, "red")
	makeMedia(t, secondPath, "blue")
	worker := startTestWorker(t, rootPath)

	request := workercontracts.StageJoinRequestV1{
		CapabilityID:        "capability:join:integration",
		CaseID:              "sha256:1111111111111111111111111111111111111111111111111111111111111111",
		DurationToleranceMS: 200,
		ExecutionID:         "execution:join:integration",
		ExpectedDurationMS:  400,
		ExpectedSourceBytes: fileSize(t, firstPath) + fileSize(t, secondPath),
		ExpectedStreamCount: 1,
		Operation:           workercontracts.StageJoinV1,
		OutputContainer:     workercontracts.OutputContainerMKV,
		Parts: []workercontracts.StageJoinPartV1{
			{
				ExpectedFingerprint: pathFingerprint(t, firstPath),
				FileID:              "file:part:first",
				PathComponents:      []string{"Movie", "first.mkv"},
			},
			{
				ExpectedFingerprint: pathFingerprint(t, secondPath),
				FileID:              "file:part:second",
				PathComponents:      []string{"Movie", "second.mkv"},
			},
		},
		RequestID:     "request:join:integration",
		RootID:        "root:downloads",
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
	}
	inspect := inspectJoin(t, worker.client, request.ExecutionID, "request:inspect:absent")
	if inspect.Success == nil ||
		inspect.Success.State != workercontracts.InspectJoinAbsent {
		t.Fatalf("inspect absent response = %#v", inspect)
	}
	response := stageJoin(t, worker.client, request)
	if response.Success == nil || response.Success.Evidence.Format.DurationMS == nil ||
		*response.Success.Evidence.Format.DurationMS < 300 ||
		*response.Success.Evidence.Format.DurationMS > 600 {
		t.Fatalf("stage response = %#v", response)
	}
	inspect = inspectJoin(t, worker.client, request.ExecutionID, "request:inspect:staged")
	if inspect.Success == nil ||
		inspect.Success.State != workercontracts.InspectJoinStaged {
		t.Fatalf("inspect staged response = %#v", inspect)
	}

	request.RequestID = "request:join:integration:retry"
	retry := stageJoin(t, worker.client, request)
	if retry.Success == nil ||
		retry.Success.ArtifactID != response.Success.ArtifactID ||
		retry.Success.ArtifactFingerprint != response.Success.ArtifactFingerprint {
		t.Fatalf("retry response = %#v, first response = %#v", retry, response)
	}

	publishRequest := workercontracts.PublishRequestV1{
		ArtifactFingerprint: response.Success.ArtifactFingerprint,
		ArtifactID:          response.Success.ArtifactID,
		Operation:           workercontracts.PublishV1,
		RequestID:           "request:publish:integration",
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	}
	published := publishJoin(t, worker.client, publishRequest)
	if published.Success == nil || published.Success.RootID != request.RootID {
		t.Fatalf("publish response = %#v", published)
	}
	inspect = inspectJoin(t, worker.client, request.ExecutionID, "request:inspect:published")
	if inspect.Success == nil ||
		inspect.Success.State != workercontracts.InspectJoinPublished {
		t.Fatalf("inspect published response = %#v", inspect)
	}
	publishedPath := filepath.Join(
		rootPath,
		filepath.Join(published.Success.PathComponents...),
	)
	if info, err := os.Stat(publishedPath); err != nil || info.Size() == 0 {
		t.Fatalf("published media: info = %#v, error = %v", info, err)
	}
	for _, sourcePath := range []string{firstPath, secondPath} {
		if info, err := os.Stat(sourcePath); err != nil || info.Size() == 0 {
			t.Fatalf("source media %q: info = %#v, error = %v", sourcePath, info, err)
		}
	}

	discardRequest := workercontracts.DiscardRequestV1{
		ArtifactFingerprint: response.Success.ArtifactFingerprint,
		ArtifactID:          response.Success.ArtifactID,
		Operation:           workercontracts.DiscardV1,
		RequestID:           "request:discard:published",
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	}
	discarded := discardJoin(t, worker.client, discardRequest)
	if discarded.Failure == nil ||
		discarded.Failure.Reason != workercontracts.DiscardArtifactPublished {
		t.Fatalf("discard response = %#v", discarded)
	}
}

func stageJoin(
	t *testing.T,
	client *http.Client,
	request workercontracts.StageJoinRequestV1,
) workercontracts.StageJoinResponseV1 {
	t.Helper()
	payload, err := workercontracts.EncodeStageJoinRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	status, data := postWorker(t, client, "/v1/join/stage", payload)
	response, err := workercontracts.DecodeStageJoinResponse(data)
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusOK || response.RequestID() != request.RequestID {
		t.Fatalf("HTTP status = %d, response = %#v", status, response)
	}
	return response
}

func publishJoin(
	t *testing.T,
	client *http.Client,
	request workercontracts.PublishRequestV1,
) workercontracts.PublishResponseV1 {
	t.Helper()
	payload, err := workercontracts.EncodePublishRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	status, data := postWorker(t, client, "/v1/join/publish", payload)
	response, err := workercontracts.DecodePublishResponse(data)
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusOK || response.RequestID() != request.RequestID {
		t.Fatalf("HTTP status = %d, response = %#v", status, response)
	}
	return response
}

func discardJoin(
	t *testing.T,
	client *http.Client,
	request workercontracts.DiscardRequestV1,
) workercontracts.DiscardResponseV1 {
	t.Helper()
	payload, err := workercontracts.EncodeDiscardRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	status, data := postWorker(t, client, "/v1/join/discard", payload)
	response, err := workercontracts.DecodeDiscardResponse(data)
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusOK || response.RequestID() != request.RequestID {
		t.Fatalf("HTTP status = %d, response = %#v", status, response)
	}
	return response
}

func inspectJoin(
	t *testing.T,
	client *http.Client,
	executionID string,
	requestID string,
) workercontracts.InspectJoinResponseV1 {
	t.Helper()
	request := workercontracts.InspectJoinRequestV1{
		ExecutionID:   executionID,
		Operation:     workercontracts.InspectJoinV1,
		RequestID:     requestID,
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
	}
	payload, err := workercontracts.EncodeInspectJoinRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	status, data := postWorker(t, client, "/v1/join/inspect", payload)
	response, err := workercontracts.DecodeInspectJoinResponse(data)
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusOK || response.RequestID() != request.RequestID {
		t.Fatalf("HTTP status = %d, response = %#v", status, response)
	}
	return response
}

func TestRunRejectsInvalidConfiguration(t *testing.T) {
	t.Parallel()

	tests := [][]string{
		nil,
		{"--socket", "/tmp/worker.sock"},
		{
			"--socket", "/tmp/worker.sock",
			"--state-directory", "/state",
			"--ffprobe", "/nix/store/ffprobe",
			"--root", "downloads=/downloads",
		},
		{
			"--socket", "/tmp/worker.sock",
			"--state-directory", "/state",
			"--ffprobe", "/nix/store/ffprobe",
			"--ffmpeg", "/nix/store/ffmpeg",
			"--root", "downloads=relative",
		},
		{
			"--socket", "/tmp/worker.sock",
			"--state-directory", "/state",
			"--ffprobe", "/nix/store/ffprobe",
			"--ffmpeg", "/nix/store/ffmpeg",
			"--root", "downloads=/downloads",
			"unexpected",
		},
		{
			"--socket", "/tmp/worker.sock",
			"--state-directory", "/state",
			"--ffprobe", "/nix/store/ffprobe",
			"--ffmpeg", "/nix/store/ffmpeg",
			"--join-timeout", "0",
			"--root", "downloads=/downloads",
		},
	}
	for _, arguments := range tests {
		if err := run(context.Background(), arguments, io.Discard); err == nil {
			t.Fatalf("arguments %q were accepted", arguments)
		}
	}
}

type testWorker struct {
	client *http.Client
}

func startTestWorker(t *testing.T, rootPath string) testWorker {
	t.Helper()
	socketPath := filepath.Join(t.TempDir(), "worker.sock")
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	arguments := []string{
		"--socket", socketPath,
		"--state-directory", filepath.Join(t.TempDir(), "state"),
		"--ffprobe", requiredEnvironment(t, "RADARR_REPAIR_TEST_FFPROBE"),
		"--ffmpeg", requiredEnvironment(t, "RADARR_REPAIR_TEST_FFMPEG"),
		"--mkvmerge", requiredEnvironment(t, "RADARR_REPAIR_TEST_MKVMERGE"),
		"--lsdvd", requiredEnvironment(t, "RADARR_REPAIR_TEST_LSDVD"),
		"--root", "root:downloads=" + rootPath,
		"--timeout", "10s",
		"--join-timeout", "10s",
		"--max-concurrent", "1",
	}
	serverDone := make(chan error, 1)
	go func() {
		serverDone <- run(ctx, arguments, io.Discard)
	}()
	waitForSocket(t, socketPath, serverDone)

	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socketPath)
		},
	}
	t.Cleanup(func() {
		transport.CloseIdleConnections()
		cancel()
		select {
		case err := <-serverDone:
			if err != nil {
				t.Errorf("stop worker: %v", err)
			}
		case <-time.After(10 * time.Second):
			t.Error("worker did not stop")
		}
		if _, err := os.Lstat(socketPath); !os.IsNotExist(err) {
			t.Errorf("worker socket remains after shutdown: %v", err)
		}
	})
	return testWorker{
		client: &http.Client{Transport: transport, Timeout: 15 * time.Second},
	}
}

func postWorker(
	t *testing.T,
	client *http.Client,
	path string,
	payload []byte,
) (int, []byte) {
	t.Helper()
	request, err := http.NewRequestWithContext(
		context.Background(),
		http.MethodPost,
		"http://worker"+path,
		bytes.NewReader(payload),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return response.StatusCode, data
}

func waitForSocket(t *testing.T, socketPath string, serverDone <-chan error) {
	t.Helper()
	timer := time.NewTimer(10 * time.Second)
	defer timer.Stop()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case err := <-serverDone:
			t.Fatalf("worker stopped before listening: %v", err)
		case <-ticker.C:
			info, err := os.Lstat(socketPath)
			if err == nil && info.Mode().Type() == os.ModeSocket &&
				info.Mode().Perm() == workerserver.SocketMode {
				return
			}
		case <-timer.C:
			t.Fatal("worker socket was not created")
		}
	}
}

func makeMedia(t *testing.T, mediaPath string, color string) {
	t.Helper()
	command := exec.Command(
		requiredEnvironment(t, "RADARR_REPAIR_TEST_FFMPEG"),
		"-hide_banner",
		"-loglevel", "error",
		"-nostdin",
		"-f", "lavfi",
		"-i", "color=c="+color+":s=16x16:r=25:d=0.2",
		"-c:v", "ffv1",
		"-y",
		mediaPath,
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("generate media fixture: %v: %s", err, output)
	}
}

func fileSize(t *testing.T, path string) int64 {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Size()
}

func pathFingerprint(t *testing.T, path string) string {
	t.Helper()
	var stat unix.Stat_t
	if err := unix.Stat(path, &stat); err != nil {
		t.Fatal(err)
	}
	return fileidentity.Snapshot{
		Device:    uint64(stat.Dev),
		Inode:     stat.Ino,
		SizeBytes: stat.Size,
		MTimeNS:   stat.Mtim.Sec*1_000_000_000 + stat.Mtim.Nsec,
	}.StrictFingerprint()
}

func requiredEnvironment(t *testing.T, name string) string {
	t.Helper()
	value := os.Getenv(name)
	if value == "" {
		t.Fatalf("%s is not set", name)
	}
	return value
}

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/fileidentity"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	workerserver "github.com/booxter/nix-config/radarr-repair/worker/server"
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
	makeMedia(t, mediaPath)
	socketPath := filepath.Join(t.TempDir(), "worker.sock")

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	arguments := []string{
		"--socket", socketPath,
		"--ffprobe", requiredEnvironment(t, "RADARR_REPAIR_TEST_FFPROBE"),
		"--root", "root:downloads=" + rootPath,
		"--timeout", "10s",
		"--max-concurrent", "1",
	}
	serverDone := make(chan error, 1)
	go func() {
		serverDone <- run(ctx, arguments, io.Discard)
	}()
	waitForSocket(t, socketPath, serverDone)

	probeRequest := workercontracts.ProbeRequestV1{
		ExpectedFingerprint: pathFingerprint(t, mediaPath),
		Operation:           workercontracts.ProbeV1,
		PathComponents:      []string{"Movie", "movie.mkv"},
		RequestID:           "request:integration",
		RootID:              "root:downloads",
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	}
	requestData, err := json.Marshal(probeRequest)
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequestWithContext(
		context.Background(),
		http.MethodPost,
		"http://worker/v1/probe",
		bytes.NewReader(requestData),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socketPath)
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second}
	httpResponse, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer httpResponse.Body.Close()
	responseData, err := io.ReadAll(httpResponse.Body)
	if err != nil {
		t.Fatal(err)
	}
	response, err := workercontracts.DecodeProbeResponse(responseData)
	if err != nil {
		t.Fatal(err)
	}
	if httpResponse.StatusCode != http.StatusOK || response.Success == nil ||
		response.RequestID() != probeRequest.RequestID ||
		len(response.Success.Evidence.Streams) != 1 {
		t.Fatalf("HTTP status = %d, response = %#v", httpResponse.StatusCode, response)
	}

	cancel()
	select {
	case err := <-serverDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("worker did not stop")
	}
	if _, err := os.Lstat(socketPath); !os.IsNotExist(err) {
		t.Fatalf("worker socket remains after shutdown: %v", err)
	}
}

func TestRunRejectsInvalidConfiguration(t *testing.T) {
	t.Parallel()

	tests := [][]string{
		nil,
		{"--socket", "/tmp/worker.sock"},
		{"--socket", "/tmp/worker.sock", "--ffprobe", "/nix/store/ffprobe"},
		{
			"--socket", "/tmp/worker.sock",
			"--ffprobe", "/nix/store/ffprobe",
			"--root", "downloads=relative",
		},
		{
			"--socket", "/tmp/worker.sock",
			"--ffprobe", "/nix/store/ffprobe",
			"--root", "downloads=/downloads",
			"unexpected",
		},
	}
	for _, arguments := range tests {
		if err := run(context.Background(), arguments, io.Discard); err == nil {
			t.Fatalf("arguments %q were accepted", arguments)
		}
	}
}

func TestRootPathsRejectDuplicateID(t *testing.T) {
	t.Parallel()

	paths := make(rootPaths)
	if err := paths.Set("downloads=/one"); err != nil {
		t.Fatal(err)
	}
	if err := paths.Set("downloads=/two"); err == nil {
		t.Fatal("duplicate root ID was accepted")
	}
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

func makeMedia(t *testing.T, mediaPath string) {
	t.Helper()
	command := exec.Command(
		requiredEnvironment(t, "RADARR_REPAIR_TEST_FFMPEG"),
		"-hide_banner",
		"-loglevel", "error",
		"-nostdin",
		"-f", "lavfi",
		"-i", "color=c=red:s=16x16:r=25:d=0.2",
		"-c:v", "ffv1",
		"-y",
		mediaPath,
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("generate media fixture: %v: %s", err, output)
	}
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
	}.Fingerprint()
}

func requiredEnvironment(t *testing.T, name string) string {
	t.Helper()
	value := os.Getenv(name)
	if value == "" {
		t.Fatalf("%s is not set", name)
	}
	return value
}

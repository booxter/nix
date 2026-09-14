package mediajoin

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/ffprobe"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

func TestRunnerJoinsRealMediaInCallerOrder(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name            string
		container       workercontracts.OutputContainer
		extension       string
		includeAudio    bool
		expectedStreams []controller.ProbeStreamKind
	}{
		{
			name:            "matroska with audio",
			container:       workercontracts.OutputContainerMKV,
			extension:       "mkv",
			includeAudio:    true,
			expectedStreams: []controller.ProbeStreamKind{controller.ProbeStreamVideo, controller.ProbeStreamAudio},
		},
		{
			name:            "silent mp4",
			container:       workercontracts.OutputContainerMP4,
			extension:       "mp4",
			expectedStreams: []controller.ProbeStreamKind{controller.ProbeStreamVideo},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			directory := t.TempDir()
			redPath := filepath.Join(directory, "01-red."+test.extension)
			bluePath := filepath.Join(directory, "02-blue."+test.extension)
			makeJoinPart(t, redPath, "red", test.container, test.includeAudio)
			makeJoinPart(t, bluePath, "blue", test.container, test.includeAudio)
			red := openTestFile(t, redPath, os.O_RDONLY)
			blue := openTestFile(t, bluePath, os.O_RDONLY)

			// Removing the input names proves the runner consumes only the open
			// descriptors and cannot silently rediscover or reorder paths.
			if err := os.Remove(redPath); err != nil {
				t.Fatal(err)
			}
			if err := os.Remove(bluePath); err != nil {
				t.Fatal(err)
			}
			outputPath := filepath.Join(directory, "joined."+test.extension)
			output := openTestFile(t, outputPath, os.O_CREATE|os.O_EXCL|os.O_RDWR)

			runner := testRunner(t, 10*time.Second)
			result, err := runner.Join(
				context.Background(),
				[]*os.File{blue, red},
				output,
				test.container,
			)
			if err != nil || result.SizeBytes <= 0 {
				t.Fatalf(
					"join: result = %#v, error = %v, cause = %v",
					result,
					err,
					errors.Unwrap(err),
				)
			}
			if info, err := output.Stat(); err != nil || info.Size() != result.SizeBytes {
				t.Fatalf("open output: info = %#v, error = %v", info, err)
			}

			evidence := probeJoinedOutput(t, output)
			if evidence.Format.DurationMS == nil || *evidence.Format.DurationMS < 700 ||
				*evidence.Format.DurationMS > 1_000 {
				t.Fatalf("joined duration = %v ms", evidence.Format.DurationMS)
			}
			if len(evidence.Streams) != len(test.expectedStreams) {
				t.Fatalf("joined streams = %#v", evidence.Streams)
			}
			for index, expected := range test.expectedStreams {
				if evidence.Streams[index].Kind == nil || *evidence.Streams[index].Kind != expected {
					t.Fatalf("joined stream %d = %#v, want %q", index, evidence.Streams[index], expected)
				}
			}

			first, last := boundaryPixels(t, outputPath)
			if int(first[2]) <= int(first[0])+50 {
				t.Fatalf("first joined pixel = RGB%v, want blue part first", first)
			}
			if int(last[0]) <= int(last[2])+50 {
				t.Fatalf("last joined pixel = RGB%v, want red part last", last)
			}
		})
	}
}

func TestRunnerReportsFFmpegFailureWithoutMediaPaths(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	firstPath := filepath.Join(directory, "private-first.mkv")
	secondPath := filepath.Join(directory, "private-second.mkv")
	if err := os.WriteFile(firstPath, []byte("not media one"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(secondPath, []byte("not media two"), 0o600); err != nil {
		t.Fatal(err)
	}
	first := openTestFile(t, firstPath, os.O_RDONLY)
	second := openTestFile(t, secondPath, os.O_RDONLY)
	output := openTestFile(
		t,
		filepath.Join(directory, "output.mkv"),
		os.O_CREATE|os.O_EXCL|os.O_RDWR,
	)

	_, err := testRunner(t, 10*time.Second).Join(
		context.Background(),
		[]*os.File{first, second},
		output,
		workercontracts.OutputContainerMKV,
	)
	var failure *Failure
	if !errors.As(err, &failure) || failure.Kind != FailureExecution ||
		failure.Diagnostics.Text == "" {
		t.Fatalf("failure = %#v, error = %v", failure, err)
	}
	if strings.Contains(failure.Diagnostics.Text, directory) ||
		strings.Contains(failure.Diagnostics.Text, filepath.Base(firstPath)) ||
		strings.Contains(failure.Diagnostics.Text, filepath.Base(secondPath)) {
		t.Fatalf("diagnostics expose media paths: %q", failure.Diagnostics.Text)
	}
}

func TestRunnerBoundsFFmpegDiagnostics(t *testing.T) {
	t.Parallel()

	writer := &diagnosticWriter{}
	data := strings.Repeat("x", maxDiagnosticBytes+1)
	written, err := writer.Write([]byte(data))
	if err != nil || written != len(data) {
		t.Fatalf("write diagnostics: bytes = %d, error = %v", written, err)
	}
	diagnostics := writer.Diagnostics()
	if len(diagnostics.Text) != maxDiagnosticBytes || !diagnostics.Truncated {
		t.Fatalf(
			"diagnostics length = %d, truncated = %t",
			len(diagnostics.Text),
			diagnostics.Truncated,
		)
	}
}

func TestRunnerHonorsCancellationAndTimeout(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := testRunner(t, time.Second).Join(
		ctx,
		nil,
		nil,
		workercontracts.OutputContainerMKV,
	); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled join error = %v", err)
	}

	first, second, output := plainJoinFiles(t)
	_, err := testRunner(t, time.Nanosecond).Join(
		context.Background(),
		[]*os.File{first, second},
		output,
		workercontracts.OutputContainerMKV,
	)
	var failure *Failure
	if !errors.As(err, &failure) || failure.Kind != FailureTimeout {
		t.Fatalf("timeout failure = %#v, error = %v", failure, err)
	}
}

func TestRunnerRejectsInvalidInputs(t *testing.T) {
	t.Parallel()

	if _, err := NewRunner("ffmpeg", time.Second); err == nil {
		t.Fatal("relative ffmpeg path was accepted")
	}
	if _, err := NewRunner("/nix/store/ffmpeg", 0); err == nil {
		t.Fatal("zero timeout was accepted")
	}
	if _, err := (*Runner)(nil).Join(
		context.Background(),
		nil,
		nil,
		workercontracts.OutputContainerMKV,
	); err == nil {
		t.Fatal("nil runner was accepted")
	}

	first, second, output := plainJoinFiles(t)
	runner := testRunner(t, time.Second)
	if _, err := runner.Join(
		context.Background(),
		[]*os.File{first},
		output,
		workercontracts.OutputContainerMKV,
	); err == nil {
		t.Fatal("one input part was accepted")
	}
	if _, err := runner.Join(
		context.Background(),
		[]*os.File{first, first},
		output,
		workercontracts.OutputContainerMKV,
	); err == nil {
		t.Fatal("duplicate input file was accepted")
	}
	if _, err := runner.Join(
		context.Background(),
		[]*os.File{first, second},
		output,
		workercontracts.OutputContainer("avi"),
	); err == nil {
		t.Fatal("unsupported output container was accepted")
	}
	if err := os.WriteFile(output.Name(), []byte("existing"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := runner.Join(
		context.Background(),
		[]*os.File{first, second},
		output,
		workercontracts.OutputContainerMKV,
	); err == nil {
		t.Fatal("non-empty output was accepted")
	}
}

func makeJoinPart(
	t *testing.T,
	path string,
	color string,
	container workercontracts.OutputContainer,
	includeAudio bool,
) {
	t.Helper()
	arguments := []string{
		"-hide_banner",
		"-loglevel", "error",
		"-nostdin",
		"-f", "lavfi",
		"-i", "color=c=" + color + ":s=16x16:r=25:d=0.4",
	}
	if includeAudio {
		arguments = append(
			arguments,
			"-f", "lavfi",
			"-i", "sine=frequency=440:sample_rate=48000:d=0.4",
			"-map", "0:v:0",
			"-map", "1:a:0",
		)
	} else {
		arguments = append(arguments, "-map", "0:v:0")
	}
	switch container {
	case workercontracts.OutputContainerMKV:
		arguments = append(arguments, "-c:v", "ffv1")
		if includeAudio {
			arguments = append(arguments, "-c:a", "pcm_s16le")
		}
	case workercontracts.OutputContainerMP4:
		arguments = append(arguments, "-c:v", "mpeg4", "-q:v", "2")
	default:
		t.Fatalf("unsupported fixture container %q", container)
	}
	arguments = append(arguments, "-y", path)
	command := exec.Command(requiredEnvironment(t, "RADARR_REPAIR_TEST_FFMPEG"), arguments...)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("make media part: %v: %s", err, output)
	}
}

func probeJoinedOutput(t *testing.T, output *os.File) controller.ProbeEvidence {
	t.Helper()
	runner, err := ffprobe.NewRunner(
		requiredEnvironment(t, "RADARR_REPAIR_TEST_FFPROBE"),
		10*time.Second,
	)
	if err != nil {
		t.Fatal(err)
	}
	evidence, err := runner.ProbeFile(context.Background(), output)
	if err != nil {
		t.Fatal(err)
	}
	return evidence
}

func boundaryPixels(t *testing.T, path string) ([3]byte, [3]byte) {
	t.Helper()
	command := exec.Command(
		requiredEnvironment(t, "RADARR_REPAIR_TEST_FFMPEG"),
		"-hide_banner",
		"-loglevel", "error",
		"-nostdin",
		"-i", path,
		"-map", "0:v:0",
		"-pix_fmt", "rgb24",
		"-f", "rawvideo",
		"pipe:1",
	)
	data, err := command.Output()
	if err != nil {
		t.Fatal(err)
	}
	const pixelBytes = 3
	if len(data) < pixelBytes || len(data)%pixelBytes != 0 {
		t.Fatalf("decoded video has %d bytes", len(data))
	}
	return [3]byte(data[:pixelBytes]), [3]byte(data[len(data)-pixelBytes:])
}

func plainJoinFiles(t *testing.T) (*os.File, *os.File, *os.File) {
	t.Helper()
	directory := t.TempDir()
	paths := []string{
		filepath.Join(directory, "first"),
		filepath.Join(directory, "second"),
	}
	for _, path := range paths {
		if err := os.WriteFile(path, []byte("data"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return openTestFile(t, paths[0], os.O_RDONLY),
		openTestFile(t, paths[1], os.O_RDONLY),
		openTestFile(
			t,
			filepath.Join(directory, "output"),
			os.O_CREATE|os.O_EXCL|os.O_RDWR,
		)
}

func openTestFile(t *testing.T, path string, flags int) *os.File {
	t.Helper()
	file, err := os.OpenFile(path, flags, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := file.Close(); err != nil {
			t.Errorf("close test file: %v", err)
		}
	})
	return file
}

func testRunner(t *testing.T, timeout time.Duration) *Runner {
	t.Helper()
	runner, err := NewRunner(requiredEnvironment(t, "RADARR_REPAIR_TEST_FFMPEG"), timeout)
	if err != nil {
		t.Fatal(err)
	}
	return runner
}

func requiredEnvironment(t *testing.T, name string) string {
	t.Helper()
	value := os.Getenv(name)
	if value == "" {
		t.Fatalf("%s is not set", name)
	}
	return value
}

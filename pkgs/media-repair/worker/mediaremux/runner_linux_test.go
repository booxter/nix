package mediaremux

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/ffprobe"
)

func TestRunnerWritesMatroskaToPreopenedFile(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	source := filepath.Join(directory, "source.wav")
	command := exec.Command(
		requiredEnvironment(t, "RADARR_REPAIR_TEST_FFMPEG"),
		"-hide_banner", "-loglevel", "error", "-f", "lavfi",
		"-i", "sine=frequency=1000:duration=1", "-c:a", "pcm_s16le", source,
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("generate media: %v: %s", err, output)
	}
	destination := filepath.Join(directory, "output.mkv")
	file, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = file.Close() })
	runner, err := NewRunner(requiredEnvironment(t, "RADARR_REPAIR_TEST_MKVMERGE"), 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	size, err := runner.Remux(context.Background(), source, file)
	if err != nil || size <= 0 {
		t.Fatalf("remux: size = %d, error = %v", size, err)
	}
	probe, err := ffprobe.NewRunner(requiredEnvironment(t, "RADARR_REPAIR_TEST_FFPROBE"), 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	evidence, err := probe.ProbeFile(context.Background(), file)
	if err != nil || evidence.Format.DurationMS == nil ||
		*evidence.Format.DurationMS < 900 || *evidence.Format.DurationMS > 1100 ||
		len(evidence.Streams) != 1 {
		t.Fatalf("remuxed media: evidence = %#v, error = %v", evidence, err)
	}
}

func TestRunnerRejectsBadOutputAndMedia(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	runner, err := NewRunner(requiredEnvironment(t, "RADARR_REPAIR_TEST_MKVMERGE"), 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	output, err := os.OpenFile(filepath.Join(directory, "output.mkv"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = output.Close() })
	if _, err := runner.Remux(context.Background(), "relative.mpls", output); err == nil {
		t.Fatal("accepted a relative playlist")
	}
	if _, err := output.Write([]byte("existing")); err != nil {
		t.Fatal(err)
	}
	if _, err := runner.Remux(context.Background(), filepath.Join(directory, "missing.mpls"), output); err == nil {
		t.Fatal("accepted a nonempty output")
	}
	if err := output.Truncate(0); err != nil {
		t.Fatal(err)
	}
	if _, err := output.Seek(0, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := runner.Remux(context.Background(), filepath.Join(directory, "missing.mpls"), output); err == nil {
		t.Fatal("accepted missing media")
	} else {
		var failure *Failure
		if !errors.As(err, &failure) || failure.Kind != FailureExecution {
			t.Fatalf("missing media failure = %v", err)
		}
	}
}

func TestRunnerHonorsCancellation(t *testing.T) {
	t.Parallel()
	runner, err := NewRunner(requiredEnvironment(t, "RADARR_REPAIR_TEST_MKVMERGE"), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := runner.Remux(ctx, "/tmp/test.mpls", nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled remux error = %v", err)
	}
}

func requiredEnvironment(t *testing.T, name string) string {
	t.Helper()
	value := os.Getenv(name)
	if value == "" {
		t.Fatalf("%s is not set", name)
	}
	return value
}

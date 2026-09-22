package ffprobe

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

func TestRunnerProbesRealMedia(t *testing.T) {
	t.Parallel()

	mediaPath := makeMediaFixture(t)
	runner := testRunner(t, 10*time.Second)
	evidence, err := runner.Probe(context.Background(), mediaPath)
	if err != nil {
		t.Fatal(err)
	}
	if !contains(evidence.Format.Names, "matroska") || !contains(evidence.Format.Names, "webm") {
		t.Fatalf("format names = %v", evidence.Format.Names)
	}
	if evidence.Format.SizeBytes == nil || *evidence.Format.SizeBytes <= 0 {
		t.Fatalf("format size = %#v", evidence.Format.SizeBytes)
	}
	if evidence.Format.DurationMS == nil || *evidence.Format.DurationMS < 150 ||
		*evidence.Format.DurationMS > 300 {
		t.Fatalf("format duration = %#v", evidence.Format.DurationMS)
	}
	if len(evidence.Streams) != 2 {
		t.Fatalf("streams = %#v", evidence.Streams)
	}
	video := evidence.Streams[0]
	if video.Kind == nil || *video.Kind != controller.ProbeStreamVideo ||
		video.Width == nil || *video.Width != 16 || video.Height == nil || *video.Height != 16 {
		t.Fatalf("video stream = %#v", video)
	}
	audio := evidence.Streams[1]
	if audio.Kind == nil || *audio.Kind != controller.ProbeStreamAudio ||
		audio.SampleRateHz == nil || *audio.SampleRateHz != 48000 ||
		!hasTag(audio.Tags, "language", "eng") {
		t.Fatalf("audio stream = %#v", audio)
	}
}

func TestRunnerProbesOpenMediaWithoutPath(t *testing.T) {
	t.Parallel()

	mediaPath := makeMediaFixture(t)
	media, err := os.Open(mediaPath)
	if err != nil {
		t.Fatal(err)
	}
	defer media.Close()
	if err := os.Remove(mediaPath); err != nil {
		t.Fatal(err)
	}

	evidence, err := testRunner(t, 10*time.Second).ProbeFile(context.Background(), media)
	if err != nil {
		t.Fatal(err)
	}
	if !contains(evidence.Format.Names, "matroska") || len(evidence.Streams) != 2 {
		t.Fatalf("evidence = %#v", evidence)
	}
}

func TestRunnerReturnsTypedFailures(t *testing.T) {
	t.Parallel()

	mediaPath := filepath.Join(t.TempDir(), "not-media.mkv")
	if err := os.WriteFile(mediaPath, []byte("not media"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := testRunner(t, 10*time.Second).Probe(context.Background(), mediaPath)
	assertFailureKind(t, err, FailureExecution)
	if strings.Contains(err.Error(), mediaPath) {
		t.Fatalf("failure exposes media path: %v", err)
	}

	validMedia := makeMediaFixture(t)
	_, err = testRunner(t, time.Nanosecond).Probe(context.Background(), validMedia)
	assertFailureKind(t, err, FailureTimeout)
}

func TestRunnerHonorsCallerCancellation(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := testRunner(t, time.Second).Probe(ctx, "/does/not/need/to/exist.mkv")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v", err)
	}
}

func TestNewRunnerRejectsInvalidConfiguration(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		executable string
		timeout    time.Duration
	}{
		{name: "empty executable", timeout: time.Second},
		{name: "relative executable", executable: "ffprobe", timeout: time.Second},
		{name: "unclean executable", executable: "/nix/store/../ffprobe", timeout: time.Second},
		{name: "zero timeout", executable: "/nix/store/ffprobe", timeout: 0},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if _, err := NewRunner(test.executable, test.timeout); err == nil {
				t.Fatal("configuration was accepted")
			}
		})
	}
}

func TestRunnerRejectsRelativeMediaPath(t *testing.T) {
	t.Parallel()

	_, err := testRunner(t, time.Second).Probe(context.Background(), "relative/movie.mkv")
	if err == nil || !strings.Contains(err.Error(), "absolute clean path") {
		t.Fatalf("error = %v", err)
	}
}

func TestRunnerRejectsMissingMediaFile(t *testing.T) {
	t.Parallel()

	_, err := testRunner(t, time.Second).ProbeFile(context.Background(), nil)
	if err == nil || !strings.Contains(err.Error(), "media file is required") {
		t.Fatalf("error = %v", err)
	}
}

func TestBoundedBufferDiscardsOverflow(t *testing.T) {
	t.Parallel()

	buffer := boundedBuffer{limit: 4}
	data := []byte("abcdef")
	written, err := buffer.Write(data)
	if err != nil || written != len(data) || !buffer.overflow || string(buffer.Bytes()) != "abcd" {
		t.Fatalf(
			"written = %d, error = %v, overflow = %t, data = %q",
			written,
			err,
			buffer.overflow,
			buffer.Bytes(),
		)
	}
}

func makeMediaFixture(t *testing.T) string {
	t.Helper()
	ffmpeg := os.Getenv("RADARR_REPAIR_TEST_FFMPEG")
	if ffmpeg == "" {
		t.Fatal("RADARR_REPAIR_TEST_FFMPEG is not set")
	}
	mediaPath := filepath.Join(t.TempDir(), "fixture.mkv")
	command := exec.Command(
		ffmpeg,
		"-hide_banner",
		"-loglevel", "error",
		"-nostdin",
		"-f", "lavfi",
		"-i", "color=c=red:s=16x16:r=25:d=0.2",
		"-f", "lavfi",
		"-i", "sine=frequency=440:sample_rate=48000:d=0.2",
		"-map", "0:v:0",
		"-map", "1:a:0",
		"-c:v", "ffv1",
		"-c:a", "pcm_s16le",
		"-metadata:s:a:0", "language=eng",
		"-shortest",
		"-y",
		mediaPath,
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("generate media fixture: %v: %s", err, output)
	}
	return mediaPath
}

func testRunner(t *testing.T, timeout time.Duration) *Runner {
	t.Helper()
	executable := os.Getenv("RADARR_REPAIR_TEST_FFPROBE")
	if executable == "" {
		t.Fatal("RADARR_REPAIR_TEST_FFPROBE is not set")
	}
	runner, err := NewRunner(executable, timeout)
	if err != nil {
		t.Fatal(err)
	}
	return runner
}

func assertFailureKind(t *testing.T, err error, want FailureKind) {
	t.Helper()
	var failure *Failure
	if !errors.As(err, &failure) || failure.Kind != want {
		t.Fatalf("error = %v, want failure kind %q", err, want)
	}
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func hasTag(tags []controller.ProbeTag, name string, value string) bool {
	for _, tag := range tags {
		if tag.Name == name && tag.Value == value {
			return true
		}
	}
	return false
}

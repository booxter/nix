package cuesheet

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestAudioTrackCountUsesNormalizedCuetoolsOutput(t *testing.T) {
	t.Parallel()
	toc := []byte("CD_DA\n\nTRACK AUDIO\nFILE \"Album.flac\" 0 03:00:00\n\nTRACK AUDIO\n")
	if got, err := audioTrackCount(toc); err != nil || got != 2 {
		t.Fatalf("audioTrackCount() = %d, %v", got, err)
	}
	if _, err := audioTrackCount([]byte("CD_ROM\nTRACK MODE1_RAW\n")); !errors.Is(err, ErrInvalid) {
		t.Fatalf("non-audio track error = %v", err)
	}
}

func TestParseCuetoolsBreakpoints(t *testing.T) {
	t.Parallel()
	want := []time.Duration{3*time.Minute + 10*time.Second + 37*time.Second/75}
	got, err := parseBreakpoints([]byte("3:10.37\n"))
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("parseBreakpoints() = %v, %v, want %v", got, err, want)
	}
	for _, data := range [][]byte{
		[]byte("3:60.00\n"), []byte("3:10.75\n"), []byte("3:10.00\n3:09.74\n"),
	} {
		if _, err := parseBreakpoints(data); !errors.Is(err, ErrInvalid) {
			t.Fatalf("parseBreakpoints(%q) error = %v", data, err)
		}
	}
}

func TestHandlerInspectsAndSplitsWithPackagedTools(t *testing.T) {
	t.Parallel()
	ffmpeg := requiredEnvironment(t, "RADARR_REPAIR_TEST_FFMPEG")
	directory := t.TempDir()
	imagePath := filepath.Join(directory, "Album.flac")
	command := exec.Command(
		ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440",
		"-t", "2", "-c:a", "flac", imagePath,
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("create audio image: %v: %s", err, output)
	}
	cuePath := filepath.Join(directory, "Album.cue")
	if err := os.WriteFile(cuePath, []byte(`FILE "Album.wav" WAVE
  TRACK 01 AUDIO
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    INDEX 01 00:01:00
`), 0o600); err != nil {
		t.Fatal(err)
	}
	input, err := os.Open(cuePath)
	if err != nil {
		t.Fatal(err)
	}
	handler, err := NewHandler(
		requiredEnvironment(t, "RADARR_REPAIR_TEST_CUECONVERT"),
		requiredEnvironment(t, "RADARR_REPAIR_TEST_CUEBREAKPOINTS"),
		ffmpeg,
	)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := handler.Inspect(context.Background(), input)
	if closeErr := input.Close(); err != nil || closeErr != nil {
		t.Fatalf("inspect = %v, close = %v", err, closeErr)
	}
	if want := []time.Duration{0, time.Second}; !reflect.DeepEqual(plan.Starts, want) {
		t.Fatalf("starts = %v, want %v", plan.Starts, want)
	}
	image, err := os.Open(imagePath)
	if err != nil {
		t.Fatal(err)
	}
	outputDirectory := filepath.Join(directory, "tracks")
	if err := os.Mkdir(outputDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	outputs, err := handler.Split(context.Background(), image, plan, outputDirectory)
	if closeErr := image.Close(); err != nil || closeErr != nil {
		t.Fatalf("split = %v, close = %v", err, closeErr)
	}
	if want := []string{"01.flac", "02.flac"}; !reflect.DeepEqual(outputs, want) {
		t.Fatalf("outputs = %v, want %v", outputs, want)
	}
	for _, name := range outputs {
		if info, err := os.Stat(filepath.Join(outputDirectory, name)); err != nil || info.Size() == 0 {
			t.Fatalf("output %s: info = %v, error = %v", name, info, err)
		}
	}
}

func requiredEnvironment(t *testing.T, name string) string {
	t.Helper()
	value := os.Getenv(name)
	if value == "" {
		t.Fatalf("%s is required", name)
	}
	return value
}

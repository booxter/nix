package dvdremux

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/commanddiagnostics"
)

func TestRunnerRetainsBoundedDiagnosticsWithoutMediaPath(t *testing.T) {
	t.Parallel()
	directory := filepath.Join(t.TempDir(), "private-movie", "VIDEO_TS")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	output, err := os.OpenFile(
		filepath.Join(t.TempDir(), "output.mkv"), os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600,
	)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = output.Close() })
	runner, err := NewRunner(requiredEnvironment(t, "RADARR_REPAIR_TEST_FFMPEG"), 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	_, err = runner.RemuxDVD(context.Background(), directory, 1, output)
	var failure *Failure
	if !errors.As(err, &failure) || failure.Kind != FailureExecution ||
		failure.Diagnostics.Text == "" || len(failure.Diagnostics.Text) > commanddiagnostics.MaxBytes {
		t.Fatalf("failure = %#v, error = %v", failure, err)
	}
	if strings.Contains(failure.Diagnostics.Text, directory) ||
		strings.Contains(failure.Diagnostics.Text, "private-movie") {
		t.Fatalf("diagnostics expose media path: %q", failure.Diagnostics.Text)
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

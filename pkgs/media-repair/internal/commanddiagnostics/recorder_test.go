package commanddiagnostics

import (
	"errors"
	"strings"
	"testing"
)

func TestRecorderBoundsAndRedactsDiagnosticOutput(t *testing.T) {
	t.Parallel()
	path := "/private/media/Lilian/VIDEO_TS"
	recorder := NewRecorder(path)
	input := strings.Repeat("x", MaxBytes-len(path)+1) + path + ": failed"
	written, err := recorder.Write([]byte(input))
	if err != nil || written != len(input) {
		t.Fatalf("write diagnostics: bytes = %d, error = %v", written, err)
	}
	diagnostics := recorder.Diagnostics()
	if strings.Contains(diagnostics.Text, path) || !strings.Contains(diagnostics.Text, "<media-path>") ||
		len(diagnostics.Text) > MaxBytes {
		t.Fatalf("diagnostics = %#v", diagnostics)
	}
}

func TestRecorderMarksDiscardedOutputAsTruncated(t *testing.T) {
	t.Parallel()
	recorder := NewRecorder()
	input := strings.Repeat("x", MaxBytes+1)
	_, _ = recorder.Write([]byte(input))
	diagnostics := recorder.Diagnostics()
	if len(diagnostics.Text) != MaxBytes || !diagnostics.Truncated {
		t.Fatalf("diagnostics = %#v", diagnostics)
	}
}

func TestAttachedDiagnosticsPreserveCause(t *testing.T) {
	t.Parallel()
	cause := errors.New("exit status 1")
	err := Attach(cause, Diagnostics{Text: "invalid input"})
	if !errors.Is(err, cause) || !strings.Contains(err.Error(), "invalid input") {
		t.Fatalf("attached error = %v", err)
	}
}

package failurelog

import (
	"bytes"
	"errors"
	"fmt"
	"strings"
	"testing"
)

type concealedError struct{ cause error }

func (err *concealedError) Error() string { return "media file access failed" }
func (err *concealedError) Unwrap() error { return err.cause }

func TestWriterReportsCorrelatedCompleteErrorChain(t *testing.T) {
	t.Parallel()
	var output bytes.Buffer
	reporter, err := NewWriter(&output)
	if err != nil {
		t.Fatal(err)
	}
	reporter.Report(Event{
		Operation: "stage_dvd_remux_v1", RequestID: "request:2",
		CaseID: "case:test", ExecutionID: "execution:test", Reason: "internal_error",
		Cause: fmt.Errorf("prepare DVD stage: %w", &concealedError{
			cause: errors.New("mkdirat .media-repair: permission denied"),
		}),
	})
	line := output.String()
	for _, expected := range []string{
		`operation="stage_dvd_remux_v1"`,
		`request_id="request:2"`,
		`case_id="case:test"`,
		`execution_id="execution:test"`,
		`reason="internal_error"`,
		`error="prepare DVD stage: media file access failed: mkdirat .media-repair: permission denied"`,
	} {
		if !strings.Contains(line, expected) {
			t.Fatalf("failure log %q does not contain %q", line, expected)
		}
	}
}

func TestWriterBoundsErrorChain(t *testing.T) {
	t.Parallel()
	var output bytes.Buffer
	reporter, err := NewWriter(&output)
	if err != nil {
		t.Fatal(err)
	}
	reporter.Report(Event{Cause: errors.New(strings.Repeat("x", maximumErrorBytes+1))})
	if !strings.Contains(output.String(), "[truncated]") || output.Len() > maximumErrorBytes+512 {
		t.Fatalf("unbounded failure log length = %d", output.Len())
	}
}

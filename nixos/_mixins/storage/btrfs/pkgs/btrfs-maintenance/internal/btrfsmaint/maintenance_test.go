//go:build linux

package btrfsmaint

import (
	"context"
	"errors"
	"os"
	"testing"
)

type fakeOperations struct {
	subvolumeExists bool
	inspectError    error
	createError     error
	chmodError      error
	resumeError     error
	startError      error
	status          string
	statusError     error
	created         bool
	resumed         bool
	started         bool
	chmodMode       os.FileMode
}

func (operations *fakeOperations) SubvolumeExists(context.Context, string) (bool, error) {
	return operations.subvolumeExists, operations.inspectError
}

func (operations *fakeOperations) CreateSubvolume(context.Context, string) error {
	operations.created = true
	return operations.createError
}

func (operations *fakeOperations) Chmod(_ string, mode os.FileMode) error {
	operations.chmodMode = mode
	return operations.chmodError
}

func (operations *fakeOperations) ResumeScrub(context.Context, string) error {
	operations.resumed = true
	return operations.resumeError
}

func (operations *fakeOperations) StartScrub(context.Context, string) error {
	operations.started = true
	return operations.startError
}

func (operations *fakeOperations) ScrubStatus(context.Context, string) (string, error) {
	return operations.status, operations.statusError
}

func TestEnsureSubvolumeCreatesOnlyWhenMissingAndAlwaysSetsMode(t *testing.T) {
	for _, exists := range []bool{false, true} {
		operations := &fakeOperations{subvolumeExists: exists}
		if err := EnsureSubvolume(context.Background(), operations, "/volume/.snapshots", 0o750); err != nil {
			t.Fatal(err)
		}
		if operations.created == exists {
			t.Errorf("exists=%v: created=%v", exists, operations.created)
		}
		if operations.chmodMode != 0o750 {
			t.Errorf("exists=%v: mode=%o, want 750", exists, operations.chmodMode)
		}
	}
}

func TestStartOrResumeScrubStartsOnlyWhenNothingCanResume(t *testing.T) {
	tests := []struct {
		name        string
		resumeError error
		wantStart   bool
		wantError   bool
	}{
		{name: "resumed"},
		{name: "nothing to resume", resumeError: ExitStatusError{Code: 2}, wantStart: true},
		{name: "resume failed", resumeError: ExitStatusError{Code: 1}, wantError: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			operations := &fakeOperations{resumeError: test.resumeError}
			err := StartOrResumeScrub(context.Background(), operations, "/volume")
			if (err != nil) != test.wantError {
				t.Fatalf("error = %v, wantError=%v", err, test.wantError)
			}
			if operations.started != test.wantStart {
				t.Errorf("started=%v, want %v", operations.started, test.wantStart)
			}
		})
	}
}

func TestResumeInterruptedScrubUsesStructuredStatus(t *testing.T) {
	for _, test := range []struct {
		name       string
		status     string
		wantResume bool
	}{
		{name: "interrupted", status: "UUID: id\nStatus: interrupted\n", wantResume: true},
		{name: "british cancelled", status: "Status: cancelled\n", wantResume: true},
		{name: "american canceled", status: "Status: canceled\n", wantResume: true},
		{name: "finished", status: "Status: finished\n"},
		{name: "unrelated word", status: "Note: scrub was interrupted before\nStatus: finished\n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			operations := &fakeOperations{status: test.status}
			if err := ResumeInterruptedScrub(context.Background(), operations, "/volume"); err != nil {
				t.Fatal(err)
			}
			if operations.resumed != test.wantResume {
				t.Errorf("resumed=%v, want %v", operations.resumed, test.wantResume)
			}
		})
	}
}

func TestMaintenanceErrorsRemainVisible(t *testing.T) {
	want := errors.New("failed")
	if err := EnsureSubvolume(context.Background(), &fakeOperations{inspectError: want}, "/volume/.snapshots", 0o750); !errors.Is(err, want) {
		t.Errorf("inspect error = %v", err)
	}
	if err := ResumeInterruptedScrub(context.Background(), &fakeOperations{statusError: want}, "/volume"); !errors.Is(err, want) {
		t.Errorf("status error = %v", err)
	}
}

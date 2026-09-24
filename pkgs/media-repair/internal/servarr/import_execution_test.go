package servarr

import (
	"context"
	"testing"
	"time"
)

func TestImportExecutionConfirmsAfterFailedCommand(t *testing.T) {
	t.Parallel()
	execution := testImportExecution{state: ImportRequested, commandID: 81}
	waiter := &testImportWaiter{}
	confirmations := 0
	markedFailed := false
	flow := newTestImportExecution(t, waiter, func(current testImportExecution) (testImportExecution, bool) {
		confirmations++
		if confirmations < 2 {
			return current, false
		}
		current.state = ImportConfirmed
		return current, true
	}, &markedFailed)

	result, err := flow.Run(context.Background(), execution, false)
	if err != nil {
		t.Fatal(err)
	}
	if result.state != ImportConfirmed || confirmations != 2 || waiter.waits != 1 || markedFailed {
		t.Fatalf(
			"result=%#v confirmations=%d waits=%d marked_failed=%v",
			result,
			confirmations,
			waiter.waits,
			markedFailed,
		)
	}
}

func TestImportExecutionFailsAfterTerminalCommandHasNoConfirmation(t *testing.T) {
	t.Parallel()
	execution := testImportExecution{state: ImportRequested, commandID: 81}
	waiter := &testImportWaiter{}
	confirmations := 0
	markedFailed := false
	flow := newTestImportExecution(t, waiter, func(current testImportExecution) (testImportExecution, bool) {
		confirmations++
		return current, false
	}, &markedFailed)

	result, err := flow.Run(context.Background(), execution, false)
	if err != nil {
		t.Fatal(err)
	}
	if result.state != ImportFailed || confirmations != terminalConfirmationChecks ||
		waiter.waits != terminalConfirmationChecks-1 || !markedFailed {
		t.Fatalf(
			"result=%#v confirmations=%d waits=%d marked_failed=%v",
			result,
			confirmations,
			waiter.waits,
			markedFailed,
		)
	}
}

type testImportExecution struct {
	state     ImportExecutionState
	commandID int64
}

type testImportWaiter struct{ waits int }

func (waiter *testImportWaiter) Wait(context.Context, time.Duration) error {
	waiter.waits++
	return nil
}

type testImportClock struct{}

func (testImportClock) Now() time.Time {
	return time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)
}

func newTestImportExecution(
	t *testing.T,
	waiter *testImportWaiter,
	confirm func(testImportExecution) (testImportExecution, bool),
	markedFailed *bool,
) *ImportExecution[testImportExecution] {
	t.Helper()
	flow, err := NewImportExecution(ImportExecutionDependencies[testImportExecution]{
		Service: "Lidarr", Operation: "manual import", Clock: testImportClock{},
		Waiter: waiter, PollInterval: time.Second,
		CaseID: func(testImportExecution) string { return "case" },
		State:  func(current testImportExecution) (ImportExecutionState, error) { return current.state, nil },
		CommandID: func(current testImportExecution) (int64, bool) {
			return current.commandID, current.commandID > 0
		},
		Submit: func(context.Context) (Command, error) {
			return Command{}, nil
		},
		ReadCommand: func(context.Context, int64) (Command, error) {
			return Command{ID: 81, Name: "ManualImport", Status: CommandFailed}, nil
		},
		Confirm: func(
			_ context.Context,
			current testImportExecution,
		) (testImportExecution, bool, error) {
			confirmed, found := confirm(current)
			return confirmed, found, nil
		},
		MarkRequested: func(
			current testImportExecution,
			commandID int64,
			_ time.Time,
		) (testImportExecution, error) {
			current.state = ImportRequested
			current.commandID = commandID
			return current, nil
		},
		MarkFailed: func(
			current testImportExecution,
			_ time.Time,
		) (testImportExecution, error) {
			*markedFailed = true
			current.state = ImportFailed
			return current, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return flow
}

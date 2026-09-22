package servarr

import (
	"context"
	"errors"
	"fmt"
	"time"
)

type ImportExecutionState uint8

const completedConfirmationChecks = 12

const (
	ImportPrepared ImportExecutionState = iota + 1
	ImportRequested
	ImportConfirmed
	ImportFailed
)

type Clock interface {
	Now() time.Time
}

type Waiter interface {
	Wait(context.Context, time.Duration) error
}

type Timer struct{}

func (Timer) Wait(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

type ImportExecutionDependencies[Execution any] struct {
	Service                 string
	Operation               string
	Clock                   Clock
	Waiter                  Waiter
	PollInterval            time.Duration
	RequireCompletionResult bool
	CaseID                  func(Execution) string
	State                   func(Execution) (ImportExecutionState, error)
	CommandID               func(Execution) (int64, bool)
	Submit                  func(context.Context) (Command, error)
	ReadCommand             func(context.Context, int64) (Command, error)
	Confirm                 func(context.Context, Execution) (Execution, bool, error)
	MarkRequested           func(Execution, int64, time.Time) (Execution, error)
	MarkFailed              func(Execution, time.Time) (Execution, error)
}

type ImportExecution[Execution any] struct {
	dependencies ImportExecutionDependencies[Execution]
}

type SubmissionUncertainError struct {
	Service   string
	Operation string
	CaseID    string
	cause     error
}

func (failure *SubmissionUncertainError) Error() string {
	message := fmt.Sprintf(
		"%s %s submission for case %q may have succeeded; refusing to repeat it",
		failure.Service,
		failure.Operation,
		failure.CaseID,
	)
	if failure.cause != nil {
		return fmt.Sprintf("%s: %v", message, failure.cause)
	}
	return message
}

func (failure *SubmissionUncertainError) Unwrap() error {
	return failure.cause
}

func NewImportExecution[Execution any](
	dependencies ImportExecutionDependencies[Execution],
) (*ImportExecution[Execution], error) {
	switch {
	case dependencies.Service == "":
		return nil, fmt.Errorf("Servarr service name is required")
	case dependencies.Operation == "":
		return nil, fmt.Errorf("Servarr import operation name is required")
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("%s import clock is required", dependencies.Service)
	case dependencies.Waiter == nil:
		return nil, fmt.Errorf("%s import poll waiter is required", dependencies.Service)
	case dependencies.PollInterval <= 0:
		return nil, fmt.Errorf("%s import poll interval must be positive", dependencies.Service)
	case dependencies.CaseID == nil || dependencies.State == nil || dependencies.CommandID == nil:
		return nil, fmt.Errorf("%s import execution reader is required", dependencies.Service)
	case dependencies.Submit == nil || dependencies.ReadCommand == nil:
		return nil, fmt.Errorf("%s import command client is required", dependencies.Service)
	case dependencies.Confirm == nil || dependencies.MarkRequested == nil ||
		dependencies.MarkFailed == nil:
		return nil, fmt.Errorf("%s import execution transitions are required", dependencies.Service)
	default:
		return &ImportExecution[Execution]{dependencies: dependencies}, nil
	}
}

// Run advances a durable import execution. newlyPrepared is true only for the
// process that persisted the prepared state before any POST was attempted.
// Seeing an existing prepared state after a restart is deliberately treated as
// an uncertain submission and never causes another POST.
func (flow *ImportExecution[Execution]) Run(
	ctx context.Context,
	execution Execution,
	newlyPrepared bool,
) (Execution, error) {
	if flow == nil {
		return execution, fmt.Errorf("Servarr import execution is not configured")
	}
	if err := ctx.Err(); err != nil {
		return execution, err
	}
	state, err := flow.dependencies.State(execution)
	if err != nil {
		return execution, err
	}
	switch state {
	case ImportConfirmed, ImportFailed:
		return execution, nil
	case ImportRequested:
		return flow.follow(ctx, execution)
	case ImportPrepared:
		if !newlyPrepared {
			return flow.resumePrepared(ctx, execution)
		}
		return flow.submit(ctx, execution)
	default:
		return execution, fmt.Errorf("unknown %s import execution state", flow.dependencies.Service)
	}
}

func (flow *ImportExecution[Execution]) submit(
	ctx context.Context,
	execution Execution,
) (Execution, error) {
	command, err := flow.dependencies.Submit(ctx)
	if err != nil {
		confirmed, found, confirmErr := flow.dependencies.Confirm(ctx, execution)
		if found {
			return confirmed, confirmErr
		}
		return execution, flow.uncertain(execution, errors.Join(
			fmt.Errorf("request %s %s: %w", flow.dependencies.Service, flow.dependencies.Operation, err),
			confirmErr,
		))
	}
	requestedAt, err := flow.now()
	if err != nil {
		return execution, flow.uncertain(execution, err)
	}
	execution, err = flow.dependencies.MarkRequested(execution, command.ID, requestedAt)
	if err != nil {
		return execution, flow.uncertain(
			execution,
			fmt.Errorf("record %s %s command: %w", flow.dependencies.Service, flow.dependencies.Operation, err),
		)
	}
	return flow.follow(ctx, execution)
}

func (flow *ImportExecution[Execution]) resumePrepared(
	ctx context.Context,
	execution Execution,
) (Execution, error) {
	confirmed, found, err := flow.dependencies.Confirm(ctx, execution)
	if found {
		return confirmed, err
	}
	return execution, flow.uncertain(execution, err)
}

func (flow *ImportExecution[Execution]) follow(
	ctx context.Context,
	execution Execution,
) (Execution, error) {
	commandID, present := flow.dependencies.CommandID(execution)
	if !present || commandID <= 0 {
		return execution, fmt.Errorf(
			"requested %s %s has no command ID",
			flow.dependencies.Service,
			flow.dependencies.Operation,
		)
	}
	completedChecks := 0
	for {
		confirmed, found, err := flow.dependencies.Confirm(ctx, execution)
		if err != nil || found {
			return confirmed, err
		}

		command, err := flow.dependencies.ReadCommand(ctx, commandID)
		if err != nil {
			return execution, fmt.Errorf(
				"read %s %s command: %w",
				flow.dependencies.Service,
				flow.dependencies.Operation,
				err,
			)
		}
		disposition, err := ClassifyImportCommand(
			flow.dependencies.Service,
			command,
			flow.dependencies.RequireCompletionResult,
		)
		if err != nil {
			return execution, err
		}
		if disposition == ImportCommandFailed {
			return flow.fail(execution)
		}
		if disposition == ImportCommandCompleted {
			completedChecks++
			if completedChecks >= completedConfirmationChecks {
				return flow.fail(execution)
			}
		} else {
			completedChecks = 0
		}
		if err := flow.dependencies.Waiter.Wait(ctx, flow.dependencies.PollInterval); err != nil {
			return execution, err
		}
	}
}

func (flow *ImportExecution[Execution]) fail(execution Execution) (Execution, error) {
	failedAt, err := flow.now()
	if err != nil {
		return execution, err
	}
	execution, err = flow.dependencies.MarkFailed(execution, failedAt)
	if err != nil {
		return execution, fmt.Errorf(
			"record failed %s %s: %w",
			flow.dependencies.Service,
			flow.dependencies.Operation,
			err,
		)
	}
	return execution, nil
}

func (flow *ImportExecution[Execution]) uncertain(
	execution Execution,
	cause error,
) error {
	return &SubmissionUncertainError{
		Service: flow.dependencies.Service, Operation: flow.dependencies.Operation,
		CaseID: flow.dependencies.CaseID(execution), cause: cause,
	}
}

func (flow *ImportExecution[Execution]) now() (time.Time, error) {
	now := flow.dependencies.Clock.Now().UTC()
	if now.IsZero() {
		return time.Time{}, fmt.Errorf("clock returned a zero time")
	}
	return now, nil
}

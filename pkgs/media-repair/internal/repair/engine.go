package repair

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

// Adapter owns media validation and the service-specific import command. The
// engine owns persistence and never repeats an uncertain external submission.
type Adapter interface {
	Repair(context.Context, jobs.Job, jobs.Attempt) (PreparedImport, error)
	Submit(context.Context, json.RawMessage) (int64, error)
	CheckImport(context.Context, jobs.Attempt) (ImportStatus, error)
}

type PreparedImport struct {
	OutputPath      string
	Request         json.RawMessage
	HistoryIDBefore int64
}

type ImportStatus struct {
	Receipt json.RawMessage
	Failure string
}

type BlockedError struct{ Reason string }

func (failure *BlockedError) Error() string { return failure.Reason }

type Engine struct {
	Store   *jobs.Store
	Adapter Adapter
	Now     func() time.Time
}

// The service scheduler runs one job at a time. An active attempt seen here
// therefore belongs to a previous run, not a concurrent execution.
func (engine *Engine) Run(ctx context.Context, id int64) error {
	job, err := engine.Store.Get(ctx, id)
	if err != nil {
		return err
	}

	if job.State == jobs.Ready {
		attempt, err := engine.Store.Start(ctx, id, engine.Now())
		if err != nil {
			return err
		}

		return engine.execute(ctx, job, attempt)
	}

	if job.State != jobs.Running && job.State != jobs.Importing {
		return nil
	}

	attempt, err := engine.Store.LatestAttempt(ctx, id)
	if err != nil {
		return err
	}
	if attempt.State == jobs.Running {
		return engine.finish(ctx, attempt, jobs.Failed, "repair interrupted before import; reconsider to retry")
	}

	return engine.reconcile(ctx, attempt)
}

func (engine *Engine) execute(ctx context.Context, job jobs.Job, attempt jobs.Attempt) error {
	prepared, err := engine.Adapter.Repair(ctx, job, attempt)
	if err != nil {
		state := jobs.Failed
		var blocked *BlockedError
		if errors.As(err, &blocked) {
			state = jobs.Blocked
		}

		return errors.Join(err, engine.finish(context.WithoutCancel(ctx), attempt, state, err.Error()))
	}

	// Persist intent before POST: losing its response must never make the
	// import appear safe to submit again after a restart.
	attempt.OutputPath = prepared.OutputPath
	attempt.ImportRequest = prepared.Request
	attempt.HistoryIDBefore = prepared.HistoryIDBefore
	attempt.State = jobs.Importing
	attempt.ImportStartedAt = engine.Now().UTC()
	attempt.UpdatedAt = attempt.ImportStartedAt
	if err := engine.Store.UpdateAttempt(ctx, attempt); err != nil {
		return err
	}

	commandID, submitErr := engine.Adapter.Submit(ctx, attempt.ImportRequest)
	if submitErr != nil {
		attempt.Reason = fmt.Sprintf("import submission uncertain: %v", submitErr)
	} else {
		attempt.CommandID = commandID
	}

	attempt.UpdatedAt = engine.Now().UTC()
	if err := engine.Store.UpdateAttempt(context.WithoutCancel(ctx), attempt); err != nil {
		return errors.Join(submitErr, err)
	}

	return errors.Join(submitErr, engine.reconcile(ctx, attempt))
}

func (engine *Engine) reconcile(ctx context.Context, attempt jobs.Attempt) error {
	status, err := engine.Adapter.CheckImport(ctx, attempt)
	if err != nil {
		attempt.Reason = fmt.Sprintf("checking import: %v", err)
	} else if len(status.Receipt) != 0 {
		attempt.State = jobs.Imported
		attempt.Reason = ""
		attempt.ImportReceipt = status.Receipt
	} else if status.Failure != "" {
		// Give history time to catch up with a completed command. Starting the
		// grace period at submission would break for long-running imports.
		if attempt.ImportTerminalAt.IsZero() {
			attempt.ImportTerminalAt = engine.Now().UTC()
		}
		attempt.Reason = "command finished; waiting for import history"
		if engine.Now().Sub(attempt.ImportTerminalAt) >= 30*time.Second {
			attempt.State = jobs.Failed
			attempt.Reason = status.Failure
		}
	} else if attempt.CommandID == 0 {
		attempt.Reason = "import submission uncertain; checking history without resubmitting"
	}

	attempt.UpdatedAt = engine.Now().UTC()
	return errors.Join(err, engine.Store.UpdateAttempt(context.WithoutCancel(ctx), attempt))
}

func (engine *Engine) finish(ctx context.Context, attempt jobs.Attempt, state jobs.State, reason string) error {
	attempt.State = state
	attempt.Reason = reason
	attempt.UpdatedAt = engine.Now().UTC()
	return engine.Store.UpdateAttempt(ctx, attempt)
}

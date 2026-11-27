package repair

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

type ConfirmationSteps struct {
	// Return the complete selection, or nil while any file is missing from history.
	FindImportedFiles func(context.Context, jobs.Attempt) ([]servarr.ImportedFile, error)
	ReadCommandStatus func(context.Context, int64) (servarr.Command, error)
	// Radarr includes a result with a completed command. Lidarr can omit it.
	RequireCompletionResult bool
}

// History confirms the import even when the submission response was lost.
// Check command status only while we are still waiting for a receipt.
func (engine *Engine) checkImport(ctx context.Context, attempt *jobs.Attempt) error {
	steps := engine.Adapter.ConfirmationSteps()
	files, err := steps.FindImportedFiles(ctx, *attempt)
	if err != nil {
		return err
	}
	if len(files) != 0 {
		attempt.State = jobs.Imported
		attempt.ImportReceipt = &servarr.ImportReceipt{Files: files}
		attempt.Reason = ""
		return nil
	}
	if attempt.CommandID == 0 {
		attempt.Reason = "import submission uncertain; checking history without resubmitting"
		return nil
	}

	command, err := steps.ReadCommandStatus(ctx, attempt.CommandID)
	if err != nil {
		return err
	}
	disposition, err := servarr.ClassifyImportCommand("Servarr", command, steps.RequireCompletionResult)
	if err != nil {
		return err
	}
	if disposition == servarr.ImportCommandPending {
		return nil
	}

	// History can lag behind a finished command. A long-running command gets
	// the same grace period because the clock starts when we see it finish.
	now := engine.Now().UTC()
	if attempt.ImportTerminalAt.IsZero() {
		attempt.ImportTerminalAt = now
	}
	attempt.Reason = "command finished; waiting for import history"
	if now.Sub(attempt.ImportTerminalAt) >= 30*time.Second {
		attempt.State = jobs.Failed
		attempt.Reason = fmt.Sprintf("import command %d finished without matching import history: %s", command.ID, command.Message)
	}
	return nil
}

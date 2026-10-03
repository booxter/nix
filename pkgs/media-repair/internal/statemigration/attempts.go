package statemigration

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
)

// Only the fields needed for conversion are decoded. Older records stay in the
// archived input tree; no old decoder or schema enters the running daemon.
type execution struct {
	State           string                              `json:"state"`
	PreparedAt      time.Time                           `json:"prepared_at"`
	UpdatedAt       time.Time                           `json:"updated_at"`
	HistoryIDBefore int64                               `json:"history_id_before"`
	CommandID       *int64                              `json:"command_id"`
	Confirmation    json.RawMessage                     `json:"confirmation"`
	Confirmations   json.RawMessage                     `json:"confirmations"`
	Import          *casestore.JoinImport               `json:"import"`
	Published       *casestore.JoinPublishedArtifact    `json:"published"`
	Failure         *casestore.JoinFailure              `json:"failure"`
	Tracks          []lidarrrepair.ImportExecutionTrack `json:"tracks"`
}

func restoreAttempt(directory string, roots map[string]string, current *convertedCase) error {
	subdirectory := "executions"
	if current.job.Service == jobs.Lidarr {
		subdirectory = "imports"
	}
	record, found, err := readJSON[execution](recordPath(filepath.Join(directory, subdirectory), current.id))
	if err != nil || !found {
		return err
	}

	// Cutover cannot resolve a live external transaction from a copied ledger.
	// Let the old controller settle it, then take the final stopped-state copy.
	if record.State == "import_prepared" || record.State == "import_requested" {
		return fmt.Errorf("case %s still has an unresolved import; settle it before cutover", current.id)
	}
	attempt := jobs.Attempt{
		State:           jobs.Failed,
		Plan:            current.job.Plan,
		HistoryIDBefore: record.HistoryIDBefore,
		StartedAt:       record.PreparedAt,
		UpdatedAt:       record.UpdatedAt,
		Reason:          "previous execution: " + record.State,
	}
	bound, found, err := readJSON[struct {
		Decision json.RawMessage `json:"decision"`
	}](recordPath(filepath.Join(directory, "execution-plans"), current.id))
	if err != nil {
		return err
	}
	if found {
		attempt.Plan = bound.Decision
	}
	if record.CommandID != nil {
		attempt.CommandID = *record.CommandID
	}
	if record.Import != nil {
		attempt.ImportRequest, err = json.Marshal(record.Import.Command)
		if err != nil {
			return err
		}
		attempt.OutputPath = record.Import.Command.File.Path
		attempt.ImportStartedAt = record.Import.PreparedAt
		attempt.HistoryIDBefore = record.Import.HistoryIDBefore
		if record.Import.CommandID != nil {
			attempt.CommandID = *record.Import.CommandID
		}
	}
	if record.Published != nil {
		root, ok := roots[record.Published.RootID]
		if !ok {
			return fmt.Errorf("unknown published media root %s", record.Published.RootID)
		}
		attempt.OutputPath = filepath.Join(append([]string{root}, record.Published.PathComponents...)...)
	}
	if record.Failure != nil {
		attempt.Reason += ": " + record.Failure.Reason
	}
	if record.State == "imported" {
		attempt.State = jobs.Imported
		attempt.Reason = ""
		attempt.ImportReceipt = record.Confirmation
		if current.job.Service == jobs.Lidarr {
			attempt.ImportReceipt = record.Confirmations
		}
		if len(attempt.ImportReceipt) == 0 || string(attempt.ImportReceipt) == "null" {
			return fmt.Errorf("imported case %s has no receipt", current.id)
		}
	}

	current.attempt = &attempt
	current.job.State = attempt.State
	current.job.Reason = attempt.Reason
	if attempt.UpdatedAt.After(current.job.UpdatedAt) {
		current.job.UpdatedAt = attempt.UpdatedAt
	}
	return nil
}

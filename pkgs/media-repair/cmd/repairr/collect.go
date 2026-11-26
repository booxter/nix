package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/inspection"
	"github.com/booxter/nix-config/media-repair/internal/repairradarr"
)

type collectionReport struct {
	QueueID  int64                   `json:"queue_id"`
	Case     *contracts.RepairCaseV3 `json:"case,omitempty"`
	Findings []string                `json:"findings,omitempty"`
	Error    string                  `json:"error,omitempty"`
}

type reportWriter struct {
	encoder  *json.Encoder
	failures int
}

// write emits one JSON line per entry. An ineligible download is a normal
// result. An inspection error also counts toward the command's exit status.
func (w *reportWriter) write(record controller.RadarrQueueRecord, result repairradarr.CollectionResult) error {
	report := collectionReport{QueueID: record.ID, Findings: result.Findings}
	if result.Err != nil {
		report.Error = result.Err.Error()
		w.failures++
	} else if result.Case != nil {
		// The planner chooses a file by ID. Only Repairr needs to know where
		// that file lives on disk and how to ask Radarr to import it.
		report.Case = &result.Case.Request
	}
	return w.encoder.Encode(report)
}

// writeRadarrQueueReport finishes reporting the queue even if an individual entry failed.
func writeRadarrQueueReport(
	ctx context.Context,
	queue controller.RadarrQueueReader,
	inspector *inspection.Inspector,
	output io.Writer,
) error {
	reports := reportWriter{encoder: json.NewEncoder(output)}
	if err := repairradarr.CollectQueue(ctx, queue, inspector, reports.write); err != nil {
		return err
	}
	if reports.failures > 0 {
		return fmt.Errorf("could not collect %d Radarr queue entries", reports.failures)
	}
	return nil
}

package repair

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
)

type QueueRemover interface {
	RemovalQueue(context.Context) ([]queuefinalize.Entry, error)
	FinalizeQueue(context.Context, int64) error
}

func RemoveTracking(ctx context.Context, client QueueRemover, job jobs.Job) error {
	entries, err := client.RemovalQueue(ctx)
	if err != nil {
		return err
	}

	var selected *queuefinalize.Entry
	for _, entry := range entries {
		if entry.QueueID == job.QueueID {
			selected = &entry
			break
		}
	}
	if selected == nil {
		return nil
	}
	if selected.DownloadID != job.DownloadID || !selected.Eligible() {
		return fmt.Errorf("queue identity or completion status changed; removal not performed")
	}

	// FinalizeQueue removes tracking only: never the download or source files.
	if err := client.FinalizeQueue(ctx, selected.QueueID); err != nil {
		return err
	}
	remaining, err := client.RemovalQueue(ctx)
	if err != nil {
		return err
	}
	for _, entry := range remaining {
		if entry.QueueID == job.QueueID && entry.DownloadID == job.DownloadID {
			return fmt.Errorf("queue removal accepted but the item is still present")
		}
	}

	return nil
}

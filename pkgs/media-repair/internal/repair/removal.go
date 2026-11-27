package repair

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
)

type QueueRemover interface {
	RemovalQueue(context.Context) ([]queuefinalize.Entry, error)
	InspectRemoval(context.Context, jobs.QueueKey) (jobs.InspectedCase, error)
	FinalizeQueue(context.Context, int64, bool) error
}

func RemoveTracking(ctx context.Context, client QueueRemover, job jobs.Job) error {
	entries, err := client.RemovalQueue(ctx)
	if err != nil {
		return err
	}

	keys := make([]jobs.QueueKey, len(entries))
	for index, entry := range entries {
		keys[index] = jobs.QueueKey{QueueID: entry.QueueID, DownloadID: entry.DownloadID}
	}
	index, err := jobs.MatchQueue(job.QueueKey(), keys)
	if err != nil {
		return err
	}
	if index < 0 {
		return nil
	}
	selected := entries[index]
	if !selected.Eligible() {
		return fmt.Errorf("queue identity or completion status changed; removal not performed")
	}

	key := jobs.QueueKey{QueueID: selected.QueueID, DownloadID: selected.DownloadID}
	if err := checkRemovalSource(ctx, client, key, job.RemovalFingerprint); err != nil {
		return err
	}

	// Preserve torrents for seeding; only SABnzbd owns disposable download output.
	removeFromClient := selected.Protocol == "usenet" && selected.DownloadClient == "SABnzbd"
	if err := client.FinalizeQueue(ctx, selected.QueueID, removeFromClient); err != nil {
		return err
	}
	remaining, err := client.RemovalQueue(ctx)
	if err != nil {
		return err
	}
	for _, entry := range remaining {
		if entry.DownloadID == job.DownloadID {
			return fmt.Errorf("queue removal accepted but the item is still present")
		}
	}

	return nil
}

// Run on every attempt, including retries after restart. A read failure can
// be retried. A different case needs a new decision from the operator.
func checkRemovalSource(ctx context.Context, client QueueRemover, key jobs.QueueKey, approved *string) error {
	if approved == nil {
		return &jobs.RemovalNeedsConfirmation{}
	}
	if *approved == "" {
		return nil
	}
	current, err := client.InspectRemoval(ctx, key)
	if err != nil {
		return err
	}
	if current.Fingerprint != *approved {
		return &jobs.RemovalNeedsConfirmation{Current: &current}
	}
	return nil
}

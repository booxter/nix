package repairradarr

import (
	"context"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
	"github.com/booxter/nix-config/media-repair/internal/radarr"
	"github.com/booxter/nix-config/media-repair/internal/repair"
)

func (adapter *Adapter) Remove(ctx context.Context, job jobs.Job) error {
	return repair.RemoveTracking(ctx, adapter, job)
}

func (adapter *Adapter) FinalizeQueue(ctx context.Context, id int64) error {
	return adapter.Client.FinalizeQueue(ctx, id)
}

func (adapter *Adapter) RemovalQueue(ctx context.Context) ([]queuefinalize.Entry, error) {
	queue, err := adapter.Client.ReadQueue(ctx)
	if err != nil {
		return nil, err
	}

	entries := make([]queuefinalize.Entry, 0, len(queue))
	for _, record := range queue {
		if record.MovieID == nil {
			movieID, found, err := adapter.Client.RecoverMovieID(ctx, record.DownloadID)
			if err != nil {
				return nil, err
			}
			if found {
				record.MovieID = &movieID
			}
		}

		entries = append(entries, radarr.FinalizationEntry(record))
	}

	return entries, nil
}

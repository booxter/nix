package repairlidarr

import (
	"context"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
	"github.com/booxter/nix-config/media-repair/internal/repair"
)

func (adapter *Adapter) Remove(ctx context.Context, job jobs.Job) error {
	return repair.RemoveTracking(ctx, adapter, job)
}

func (adapter *Adapter) FinalizeQueue(ctx context.Context, id int64) error {
	return adapter.Client.FinalizeQueue(ctx, id)
}

func (adapter *Adapter) RemovalQueue(ctx context.Context) ([]queuefinalize.Entry, error) {
	return lidarr.ReadFinalizationEntries(ctx, adapter.Client)
}

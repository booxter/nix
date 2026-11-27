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

func (adapter *Adapter) FinalizeQueue(ctx context.Context, id int64, removeFromClient bool) error {
	return adapter.Client.FinalizeQueue(ctx, id, removeFromClient)
}

func (adapter *Adapter) RemovalQueue(ctx context.Context) ([]queuefinalize.Entry, error) {
	return lidarr.ReadFinalizationEntries(ctx, adapter.Client)
}

// Inspect the download itself. The saved workspace used for import can
// still exist after the original download disappears.
func (adapter *Adapter) InspectRemoval(ctx context.Context, key jobs.QueueKey) (jobs.InspectedCase, error) {
	entry, err := adapter.findQueue(ctx, key)
	if err != nil {
		return jobs.InspectedCase{}, err
	}
	result := adapter.Inspector.Inspect(ctx, entry, nil)
	if result.Err != nil {
		return jobs.InspectedCase{}, result.Err
	}
	if err := repair.CheckEligibility(result.Findings); err != nil {
		return jobs.InspectedCase{}, err
	}
	return encodeEvidence(*result.Case)
}

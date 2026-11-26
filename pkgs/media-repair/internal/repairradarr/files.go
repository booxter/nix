package repairradarr

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

// prepareSource chooses the files once so the probe results and Radarr's
// import options describe the same download or extracted archive.
func (inspector *Inspector) prepareSource(
	ctx context.Context,
	correlation controller.DownloadCorrelation,
) (controller.VideoSource, error) {
	inventory, err := inspector.dependencies.Files.Inventory(ctx, correlation)
	if err != nil {
		return controller.VideoSource{}, fmt.Errorf("inventory download files: %w", err)
	}

	if inspector.dependencies.Archives != nil {
		extracted, found, err := inspector.dependencies.Archives.MaterializeVideo(ctx, correlation.Radarr.ID, inventory)
		if err != nil {
			return controller.VideoSource{}, fmt.Errorf("materialize archive video: %w", err)
		}
		if found {
			return extracted, nil
		}
	}
	return controller.VideoSource{Root: correlation.DownloadRoot, Inventory: inventory}, nil
}

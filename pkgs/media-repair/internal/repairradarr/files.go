package repairradarr

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
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

// collectDiscChoices finds Blu-ray playlists and DVD titles that Repairr could turn into a movie file.
func (inspector *Inspector) collectDiscChoices(
	ctx context.Context,
	inventory controller.FileInventory,
) ([]mkvmerge.Candidate, []dvdvideo.Candidate, error) {
	var playlists []mkvmerge.Candidate
	var err error
	if inspector.dependencies.Playlists != nil {
		playlists, err = mkvmerge.ListFeaturePlaylists(
			ctx, inventory, inspector.dependencies.Playlists,
		)
		if err != nil {
			return nil, nil, fmt.Errorf("identify Blu-ray playlists: %w", err)
		}
	}
	var dvdTitles []dvdvideo.Candidate
	if inspector.dependencies.DVDs != nil {
		dvdTitles, err = dvdvideo.ListRemuxableTitles(
			ctx, inventory, inspector.dependencies.DVDs,
		)
		if err != nil {
			return nil, nil, fmt.Errorf("identify DVD titles: %w", err)
		}
	}
	return playlists, dvdTitles, nil
}

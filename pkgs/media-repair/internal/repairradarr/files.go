package repairradarr

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
)

type sourceFacts struct {
	folder    string
	inventory controller.FileInventory
	probes    []controller.FileProbe
}

// collectSource finds the files Repairr can use, examines their media streams,
// and identifies the folder Radarr should scan for imports.
func (inspector *Inspector) collectSource(
	callerContext context.Context,
	collectionContext context.Context,
	correlation controller.DownloadCorrelation,
) (sourceFacts, error) {
	inventory, err := inspector.dependencies.Files.Inventory(collectionContext, correlation)
	if err != nil {
		return sourceFacts{}, fmt.Errorf("inventory download files: %w", err)
	}
	files := sourceFacts{folder: correlation.DownloadRoot, inventory: inventory}
	if inspector.dependencies.Archives != nil {
		extracted, found, err := inspector.dependencies.Archives.MaterializeVideo(
			collectionContext, correlation.Radarr.ID, inventory,
		)
		if err != nil {
			return sourceFacts{}, fmt.Errorf("materialize archive video: %w", err)
		}
		if found {
			// Ask Radarr about files in the extracted folder. The file list and
			// probe results must describe those same files.
			files = sourceFacts{
				folder:    extracted.Root,
				inventory: extracted.Inventory,
				probes:    extracted.Probes,
			}
		}
	}
	if files.probes == nil {
		files.probes, err = controller.ProbeVideoFiles(
			callerContext, collectionContext, files.inventory, inspector.dependencies.Probes,
		)
		if err != nil {
			return sourceFacts{}, err
		}
	}
	return files, nil
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

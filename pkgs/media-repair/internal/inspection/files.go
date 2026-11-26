package inspection

import (
	"context"
	"errors"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
)

type sourceFacts struct {
	folder    string
	inventory controller.FileInventory
	probes    []casebuilder.FileProbe
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
		files.probes, err = inspector.collectProbes(callerContext, collectionContext, files.inventory)
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

// collectProbes reads media details for each candidate file and records gaps
// when time runs out. Canceling the whole scan discards the partial results.
func (inspector *Inspector) collectProbes(
	callerContext context.Context,
	collectionContext context.Context,
	inventory controller.FileInventory,
) ([]casebuilder.FileProbe, error) {
	paths := make(map[controller.FileID]string, len(inventory.Paths))
	for _, mapping := range inventory.Paths {
		if _, duplicate := paths[mapping.FileID]; duplicate {
			return nil, fmt.Errorf("inventory contains duplicate path for file %q", mapping.FileID)
		}
		paths[mapping.FileID] = mapping.AbsolutePath
	}

	probes := make([]casebuilder.FileProbe, 0, len(inventory.Files))
	for _, assessment := range controller.ClassifyMediaFiles(inventory) {
		outcome, err := inspector.probeFile(callerContext, collectionContext, assessment, paths)
		if err != nil {
			return nil, err
		}
		probes = append(probes, casebuilder.FileProbe{FileID: assessment.File.ID, Outcome: outcome})
	}
	return probes, nil
}

// probeFile records why a file was skipped. A probe can run out of time
// before the helper starts or while the helper is reading the file.
func (inspector *Inspector) probeFile(
	scanCtx, probeCtx context.Context,
	assessment controller.MediaFileAssessment,
	paths map[controller.FileID]string,
) (controller.MediaProbeOutcome, error) {
	if !assessment.ProbeCandidate() {
		return controller.UncollectedMediaProbe(controller.MediaProbeNotCandidate), nil
	}

	err := probeCtx.Err()
	if err == nil {
		path, ok := paths[assessment.File.ID]
		if !ok {
			return controller.MediaProbeOutcome{}, fmt.Errorf("candidate file %q has no local path", assessment.File.ID)
		}
		target := controller.MediaProbeTarget{AbsolutePath: path, Fingerprint: assessment.File.Fingerprint}
		outcome, probeErr := inspector.dependencies.Probes.Probe(probeCtx, target)
		if probeErr == nil {
			return outcome, nil
		}
		err = fmt.Errorf("probe candidate file %q: %w", assessment.File.ID, probeErr)
	}

	if scanErr := scanCtx.Err(); scanErr != nil {
		return controller.MediaProbeOutcome{}, scanErr
	}
	if errors.Is(probeCtx.Err(), context.DeadlineExceeded) {
		return controller.UncollectedMediaProbe(controller.MediaProbeCollectionLimit), nil
	}
	return controller.MediaProbeOutcome{}, err
}

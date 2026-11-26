package repairradarr

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
	"github.com/booxter/nix-config/media-repair/internal/pipeline"
)

var radarrCollectors = pipeline.Collectors[collectionInput, casebuilder.Observation]{
	collectMovie,
	collectHistory,
	collectFileProbes,
	collectImportOptions,
	collectBluRayPlaylists,
	collectDVDTitles,
}

type addFact = pipeline.AddFact[casebuilder.Observation]

type collectionInput struct {
	movieID    int64
	downloadID string
	source     controller.VideoSource
	radarr     RadarrReader
	probes     controller.MediaProbeReader
	playlists  mkvmerge.Identifier
	dvds       dvdvideo.Identifier

	// Probing records missing results when collection times out. Canceling
	// the whole scan stops probing with an error instead.
	scanCtx context.Context
}

func collectMovie(ctx context.Context, in collectionInput) (addFact, error) {
	if in.movieID <= 0 {
		return nil, nil
	}
	movie, err := in.radarr.ReadMovie(ctx, in.movieID)
	if err != nil {
		return nil, fmt.Errorf("read Radarr movie: %w", err)
	}
	return func(facts *casebuilder.Observation) { facts.Movie = &movie }, nil
}

func collectHistory(ctx context.Context, in collectionInput) (addFact, error) {
	if in.movieID <= 0 {
		return nil, nil
	}
	history, err := in.radarr.ReadHistory(ctx, in.movieID, in.downloadID)
	if err != nil {
		return nil, fmt.Errorf("read Radarr history: %w", err)
	}
	return func(facts *casebuilder.Observation) { facts.History = history }, nil
}

func collectFileProbes(ctx context.Context, in collectionInput) (addFact, error) {
	probes, err := in.source.ProbeFiles(in.scanCtx, ctx, in.probes)
	if err != nil {
		return nil, err
	}
	return func(facts *casebuilder.Observation) { facts.Probes = probes }, nil
}

// Ask Radarr about the folder we inspected, which may contain files extracted from an archive.
func collectImportOptions(ctx context.Context, in collectionInput) (addFact, error) {
	if in.movieID <= 0 {
		return nil, nil
	}
	imports, err := in.radarr.ReadManualImports(ctx, controller.RadarrManualImportQuery{
		MovieID: in.movieID, DownloadID: in.downloadID, Folder: in.source.Root,
	})
	if err != nil {
		return nil, fmt.Errorf("read Radarr manual imports: %w", err)
	}
	return func(facts *casebuilder.Observation) { facts.ManualImports = imports }, nil
}

func collectBluRayPlaylists(ctx context.Context, in collectionInput) (addFact, error) {
	if in.playlists == nil {
		return nil, nil
	}
	playlists, err := mkvmerge.ListFeaturePlaylists(ctx, in.source.Inventory, in.playlists)
	if err != nil {
		return nil, fmt.Errorf("identify Blu-ray playlists: %w", err)
	}
	return func(facts *casebuilder.Observation) { facts.BluRayPlaylists = playlists }, nil
}

func collectDVDTitles(ctx context.Context, in collectionInput) (addFact, error) {
	if in.dvds == nil {
		return nil, nil
	}
	titles, err := dvdvideo.ListRemuxableTitles(ctx, in.source.Inventory, in.dvds)
	if err != nil {
		return nil, fmt.Errorf("identify DVD titles: %w", err)
	}
	return func(facts *casebuilder.Observation) { facts.DVDTitles = titles }, nil
}

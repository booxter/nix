package repairradarr

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
)

type RadarrReader interface {
	controller.RadarrMovieReader
	controller.RadarrHistoryReader
	controller.RadarrManualImportReader
}

type VideoArchiveMaterializer interface {
	MaterializeVideo(
		context.Context,
		int64,
		controller.FileInventory,
	) (controller.VideoSource, bool, error)
}

type InspectorConfig struct {
	Clock             controller.Clock
	Radarr            RadarrReader
	Downloads         controller.DownloadResolver
	Files             controller.FileInventoryReader
	Probes            controller.MediaProbeReader
	Playlists         mkvmerge.Identifier
	DVDs              dvdvideo.Identifier
	Archives          VideoArchiveMaterializer
	CollectionTimeout time.Duration
}

type Inspector struct {
	dependencies InspectorConfig
}

// NewInspector requires readers for the movie, download, and files. Archive extraction
// and disc inspection are optional.
func NewInspector(dependencies InspectorConfig) (*Inspector, error) {
	switch {
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("inspection clock is required")
	case dependencies.Radarr == nil:
		return nil, fmt.Errorf("Radarr reader is required")
	case dependencies.Downloads == nil:
		return nil, fmt.Errorf("download reader is required")
	case dependencies.Files == nil:
		return nil, fmt.Errorf("file inventory reader is required")
	case dependencies.Probes == nil:
		return nil, fmt.Errorf("media probe reader is required")
	case dependencies.CollectionTimeout <= 0:
		return nil, fmt.Errorf("collection timeout must be positive")
	default:
		return &Inspector{dependencies: dependencies}, nil
	}
}

// Inspect resolves the queue entry and returns all eligibility findings before
// reading any files. Only an eligible entry can produce a case.
func (inspector *Inspector) Inspect(ctx context.Context, record controller.RadarrQueueRecord) CollectionResult {
	if inspector == nil || inspector.dependencies.Clock == nil {
		return CollectionResult{Err: fmt.Errorf("inspector is not configured")}
	}
	if err := ctx.Err(); err != nil {
		return CollectionResult{Err: err}
	}
	return collection.Inspect(ctx, inspector, record)
}

// collect builds a planner case for an entry that passed the pipeline's checks.
// Its time limit starts after the movie and download lookup.
func (inspector *Inspector) collect(ctx context.Context, entry resolvedEntry) (casebuilder.Assembly, error) {
	collectionContext, cancel := controller.WithCollectionTimeout(ctx, inspector.dependencies.CollectionTimeout)
	defer cancel()

	correlation := *entry.source
	source, err := inspector.prepareSource(collectionContext, correlation)
	if err != nil {
		return casebuilder.Assembly{}, err
	}

	input := collectionInput{
		movieID:    *entry.record.MovieID,
		downloadID: correlation.Radarr.DownloadID,
		source:     source,
		radarr:     inspector.dependencies.Radarr,
		probes:     inspector.dependencies.Probes,
		playlists:  inspector.dependencies.Playlists,
		dvds:       inspector.dependencies.DVDs,
	}

	facts := casebuilder.Observation{Correlation: correlation, Inventory: source.Inventory}
	if err := radarrCollectors.Collect(collectionContext, input, &facts); err != nil {
		return casebuilder.Assembly{}, err
	}

	facts.ObservedAt = inspector.dependencies.Clock.Now()
	assembly, err := casebuilder.Assemble(facts)
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("assemble repair case: %w", err)
	}
	return assembly, nil
}

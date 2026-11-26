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

// Inspect rechecks a planned entry before execution. If the queue is no
// longer eligible, there is no need to open the download again.
func (inspector *Inspector) Inspect(
	ctx context.Context,
	record controller.RadarrQueueRecord,
) (casebuilder.Assembly, error) {
	if inspector == nil || inspector.dependencies.Clock == nil {
		return casebuilder.Assembly{}, fmt.Errorf("inspector is not configured")
	}
	if err := ctx.Err(); err != nil {
		return casebuilder.Assembly{}, err
	}
	collectionContext, cancel := context.WithTimeout(ctx, inspector.dependencies.CollectionTimeout)
	defer cancel()

	assessment := controller.ClassifyRepairCandidate(record, inspector.dependencies.Downloads)
	if !assessment.Eligible() {
		return casebuilder.Assembly{}, fmt.Errorf("Radarr queue record %d is ineligible: %v", record.ID, assessment.RejectionReasons)
	}
	entry := resolvedEntry{record: record, sourceSupported: true}
	entry, err := inspector.lookUpMovieAndDownload(collectionContext, entry)
	if err != nil {
		return casebuilder.Assembly{}, err
	}
	if entry.source == nil {
		return casebuilder.Assembly{}, fmt.Errorf("download for queue record %d was not found", record.ID)
	}
	if !entry.source.Eligible() {
		return casebuilder.Assembly{}, fmt.Errorf(
			"queue record %d has an ineligible download correlation: %v",
			record.ID, entry.source.RejectionReasons,
		)
	}
	return inspector.buildCase(ctx, collectionContext, *entry.source)
}

// collect builds a planner case for an entry that passed the pipeline's checks.
// Its time limit starts after the movie and download lookup.
func (inspector *Inspector) collect(ctx context.Context, entry resolvedEntry) (casebuilder.Assembly, error) {
	if entry.source == nil {
		return casebuilder.Assembly{}, fmt.Errorf("queue record %d has no resolved download", entry.record.ID)
	}
	collectionContext, cancel := context.WithTimeout(ctx, inspector.dependencies.CollectionTimeout)
	defer cancel()
	return inspector.buildCase(ctx, collectionContext, *entry.source)
}

// buildCase combines Radarr's records with the files on disk so each option
// offered to the planner refers to files Repairr actually inspected.
func (inspector *Inspector) buildCase(
	callerContext context.Context,
	collectionContext context.Context,
	correlation controller.DownloadCorrelation,
) (casebuilder.Assembly, error) {
	source, err := inspector.prepareSource(collectionContext, correlation)
	if err != nil {
		return casebuilder.Assembly{}, err
	}

	input := collectionInput{
		scanCtx:    callerContext,
		downloadID: correlation.Radarr.DownloadID,
		source:     source,
		radarr:     inspector.dependencies.Radarr,
		probes:     inspector.dependencies.Probes,
		playlists:  inspector.dependencies.Playlists,
		dvds:       inspector.dependencies.DVDs,
	}
	if id := correlation.Radarr.MovieID; id != nil {
		input.movieID = *id
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

package inspection

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/archivematerialize"
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
	) (archivematerialize.Source, bool, error)
}

type Dependencies struct {
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

type IneligibleError struct {
	QueueID int64
	Reasons []controller.CandidateRejectionReason
}

func (failure *IneligibleError) Error() string {
	return fmt.Sprintf("Radarr queue record %d is ineligible: %v", failure.QueueID, failure.Reasons)
}

type Inspector struct {
	dependencies Dependencies
}

// New requires readers for the movie, download, and files. Archive extraction
// and disc inspection are optional.
func New(dependencies Dependencies) (*Inspector, error) {
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

// The daemon calls Inspect for one queue entry at a time. It skips ineligible
// entries before contacting the download client. All reads share one deadline.
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
		return casebuilder.Assembly{}, &IneligibleError{QueueID: record.ID, Reasons: assessment.RejectionReasons}
	}
	entry := ResolvedEntry{record: record, sourceSupported: true}
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

// Collect builds a planner case for an entry that passed the pipeline's checks.
// Its time limit starts after the movie and download lookup.
func (inspector *Inspector) Collect(ctx context.Context, entry ResolvedEntry) (casebuilder.Assembly, error) {
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
	record := correlation.Radarr
	library, err := inspector.collectMovie(collectionContext, record)
	if err != nil {
		return casebuilder.Assembly{}, err
	}
	source, err := inspector.collectSource(callerContext, collectionContext, correlation)
	if err != nil {
		return casebuilder.Assembly{}, err
	}
	imports, err := inspector.collectImports(collectionContext, record, source.folder)
	if err != nil {
		return casebuilder.Assembly{}, err
	}
	playlists, dvdTitles, err := inspector.collectDiscChoices(collectionContext, source.inventory)
	if err != nil {
		return casebuilder.Assembly{}, err
	}

	assembly, err := casebuilder.Assemble(casebuilder.Observation{
		ObservedAt:      inspector.dependencies.Clock.Now(),
		Correlation:     correlation,
		Movie:           library.movie,
		History:         library.history,
		ManualImports:   imports,
		Inventory:       source.inventory,
		Probes:          source.probes,
		BluRayPlaylists: playlists,
		DVDTitles:       dvdTitles,
	})
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("assemble repair case: %w", err)
	}
	return assembly, nil
}

type movieFacts struct {
	movie   *controller.RadarrMovie
	history []controller.RadarrHistoryEvent
}

// collectMovie gets the library record and this download's history for the case.
func (inspector *Inspector) collectMovie(ctx context.Context, record controller.RadarrQueueRecord) (movieFacts, error) {
	if record.MovieID == nil || *record.MovieID <= 0 {
		return movieFacts{}, nil
	}
	movieID := *record.MovieID
	movie, err := inspector.dependencies.Radarr.ReadMovie(ctx, movieID)
	if err != nil {
		return movieFacts{}, fmt.Errorf("read Radarr movie: %w", err)
	}
	history, err := inspector.dependencies.Radarr.ReadHistory(ctx, movieID, record.DownloadID)
	if err != nil {
		return movieFacts{}, fmt.Errorf("read Radarr history: %w", err)
	}
	return movieFacts{movie: &movie, history: history}, nil
}

// collectImports asks Radarr which files it sees in the inspected folder for this movie.
func (inspector *Inspector) collectImports(
	ctx context.Context,
	record controller.RadarrQueueRecord,
	folder string,
) ([]controller.RadarrManualImport, error) {
	if record.MovieID == nil || *record.MovieID <= 0 {
		return nil, nil
	}
	imports, err := inspector.dependencies.Radarr.ReadManualImports(ctx, controller.RadarrManualImportQuery{
		MovieID: *record.MovieID, DownloadID: record.DownloadID, Folder: folder,
	})
	if err != nil {
		return nil, fmt.Errorf("read Radarr manual imports: %w", err)
	}
	return imports, nil
}

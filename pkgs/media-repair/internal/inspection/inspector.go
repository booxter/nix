package inspection

import (
	"context"
	"errors"
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

type assembleFunc func(casebuilder.Observation) (casebuilder.Assembly, error)

type Inspector struct {
	dependencies Dependencies
	assemble     assembleFunc
}

func New(dependencies Dependencies) (*Inspector, error) {
	return newInspector(dependencies, casebuilder.Assemble)
}

func newInspector(dependencies Dependencies, assemble assembleFunc) (*Inspector, error) {
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
	case assemble == nil:
		return nil, fmt.Errorf("case assembler is required")
	default:
		return &Inspector{dependencies: dependencies, assemble: assemble}, nil
	}
}

func (inspector *Inspector) Inspect(
	ctx context.Context,
	record controller.RadarrQueueRecord,
) (casebuilder.Assembly, error) {
	if inspector == nil || inspector.assemble == nil {
		return casebuilder.Assembly{}, fmt.Errorf("inspector is not configured")
	}
	if err := ctx.Err(); err != nil {
		return casebuilder.Assembly{}, err
	}
	collectionContext, cancel := context.WithTimeout(ctx, inspector.dependencies.CollectionTimeout)
	defer cancel()

	assessment := controller.ClassifyRepairCandidate(record, inspector.dependencies.Downloads)
	if !assessment.Eligible() {
		return casebuilder.Assembly{}, fmt.Errorf(
			"Radarr queue record %d is ineligible: %v", record.ID, assessment.RejectionReasons,
		)
	}
	return inspector.inspectRecord(ctx, collectionContext, record)
}

func (inspector *Inspector) inspectRecord(
	callerContext context.Context,
	collectionContext context.Context,
	record controller.RadarrQueueRecord,
) (casebuilder.Assembly, error) {
	if record.MovieID == nil {
		movieID, found, err := inspector.dependencies.Radarr.RecoverMovieID(
			collectionContext,
			record.DownloadID,
		)
		if err != nil {
			return casebuilder.Assembly{}, fmt.Errorf("recover Radarr movie identity: %w", err)
		}
		if found {
			record.MovieID = &movieID
		}
	}

	download, found, err := inspector.dependencies.Downloads.Resolve(collectionContext, record)
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("read download: %w", err)
	}
	if !found {
		return casebuilder.Assembly{}, fmt.Errorf(
			"download for queue record %d was not found",
			record.ID,
		)
	}
	correlation := controller.CorrelateDownload(record, download)
	if !correlation.Eligible() {
		return casebuilder.Assembly{}, fmt.Errorf(
			"queue record %d has an ineligible download correlation: %v",
			record.ID,
			correlation.RejectionReasons,
		)
	}

	var movie *controller.RadarrMovie
	var history []controller.RadarrHistoryEvent
	var manualImports []controller.RadarrManualImport
	if record.MovieID != nil && *record.MovieID > 0 {
		movieID := *record.MovieID
		observedMovie, readErr := inspector.dependencies.Radarr.ReadMovie(collectionContext, movieID)
		if readErr != nil {
			return casebuilder.Assembly{}, fmt.Errorf("read Radarr movie: %w", readErr)
		}
		movie = &observedMovie
		history, readErr = inspector.dependencies.Radarr.ReadHistory(
			collectionContext,
			movieID,
			record.DownloadID,
		)
		if readErr != nil {
			return casebuilder.Assembly{}, fmt.Errorf("read Radarr history: %w", readErr)
		}
	}
	inventory, err := inspector.dependencies.Files.Inventory(collectionContext, correlation)
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("inventory download files: %w", err)
	}
	inspectionRoot := correlation.DownloadRoot
	var probes []casebuilder.FileProbe
	if inspector.dependencies.Archives != nil {
		materialized, found, materializeErr := inspector.dependencies.Archives.MaterializeVideo(
			collectionContext, record.ID, inventory,
		)
		if materializeErr != nil {
			return casebuilder.Assembly{}, fmt.Errorf("materialize archive video: %w", materializeErr)
		}
		if found {
			inspectionRoot = materialized.Root
			inventory = materialized.Inventory
			probes = materialized.Probes
		}
	}
	if probes == nil {
		probes, err = inspector.collectProbes(callerContext, collectionContext, inventory)
		if err != nil {
			return casebuilder.Assembly{}, err
		}
	}
	if movie != nil {
		manualImports, err = inspector.dependencies.Radarr.ReadManualImports(
			collectionContext,
			controller.RadarrManualImportQuery{
				MovieID: movie.ID, DownloadID: record.DownloadID, Folder: inspectionRoot,
			},
		)
		if err != nil {
			return casebuilder.Assembly{}, fmt.Errorf("read Radarr manual imports: %w", err)
		}
	}
	var playlists []mkvmerge.Candidate
	if inspector.dependencies.Playlists != nil {
		playlists, err = mkvmerge.ListFeaturePlaylists(
			collectionContext, inventory, inspector.dependencies.Playlists,
		)
		if err != nil {
			return casebuilder.Assembly{}, fmt.Errorf("identify Blu-ray playlists: %w", err)
		}
	}
	var dvdTitles []dvdvideo.Candidate
	if inspector.dependencies.DVDs != nil {
		dvdTitles, err = dvdvideo.ListRemuxableTitles(
			collectionContext, inventory, inspector.dependencies.DVDs,
		)
		if err != nil {
			return casebuilder.Assembly{}, fmt.Errorf("identify DVD titles: %w", err)
		}
	}

	assembly, err := inspector.assemble(casebuilder.Observation{
		ObservedAt:      inspector.dependencies.Clock.Now(),
		Correlation:     correlation,
		Movie:           movie,
		History:         history,
		ManualImports:   manualImports,
		Inventory:       inventory,
		Probes:          probes,
		BluRayPlaylists: playlists,
		DVDTitles:       dvdTitles,
	})
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("assemble repair case: %w", err)
	}
	return assembly, nil
}

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

	assessments := controller.ClassifyMediaFiles(inventory)
	probes := make([]casebuilder.FileProbe, 0, len(assessments))
	for _, assessment := range assessments {
		if !assessment.ProbeCandidate() {
			probes = append(probes, casebuilder.FileProbe{
				FileID: assessment.File.ID,
				Outcome: controller.UncollectedMediaProbe(
					controller.MediaProbeNotCandidate,
				),
			})
			continue
		}
		if err := collectionContext.Err(); err != nil {
			if callerErr := callerContext.Err(); callerErr != nil {
				return nil, callerErr
			}
			if !errors.Is(err, context.DeadlineExceeded) {
				return nil, err
			}
			probes = append(probes, casebuilder.FileProbe{
				FileID: assessment.File.ID,
				Outcome: controller.UncollectedMediaProbe(
					controller.MediaProbeCollectionLimit,
				),
			})
			continue
		}
		path, ok := paths[assessment.File.ID]
		if !ok {
			return nil, fmt.Errorf("candidate file %q has no local path", assessment.File.ID)
		}
		outcome, err := inspector.dependencies.Probes.Probe(collectionContext, controller.MediaProbeTarget{
			AbsolutePath: path,
			Fingerprint:  assessment.File.Fingerprint,
		})
		if err != nil {
			if callerErr := callerContext.Err(); callerErr != nil {
				return nil, callerErr
			}
			if errors.Is(collectionContext.Err(), context.DeadlineExceeded) {
				probes = append(probes, casebuilder.FileProbe{
					FileID: assessment.File.ID,
					Outcome: controller.UncollectedMediaProbe(
						controller.MediaProbeCollectionLimit,
					),
				})
				continue
			}
			return nil, fmt.Errorf("probe candidate file %q: %w", assessment.File.ID, err)
		}
		probes = append(probes, casebuilder.FileProbe{
			FileID: assessment.File.ID, Outcome: outcome,
		})
	}
	return probes, nil
}

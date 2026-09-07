package inspection

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

type RadarrReader interface {
	controller.RadarrQueueReader
	controller.RadarrMovieReader
	controller.RadarrHistoryReader
	controller.RadarrManualImportReader
}

type Dependencies struct {
	Clock             controller.Clock
	Radarr            RadarrReader
	Transmission      controller.TransmissionReader
	Files             controller.FileInventoryReader
	Probes            controller.MediaProbeReader
	CollectionTimeout time.Duration
}

type Selection struct {
	// QueueID zero selects the only eligible queue record. An explicit ID is
	// required when more than one record is eligible.
	QueueID int64
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
	case dependencies.Transmission == nil:
		return nil, fmt.Errorf("Transmission reader is required")
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
	selection Selection,
) (casebuilder.Assembly, error) {
	if inspector == nil || inspector.assemble == nil {
		return casebuilder.Assembly{}, fmt.Errorf("inspector is not configured")
	}
	if err := ctx.Err(); err != nil {
		return casebuilder.Assembly{}, err
	}
	if selection.QueueID < 0 {
		return casebuilder.Assembly{}, fmt.Errorf("queue ID must not be negative")
	}
	collectionContext, cancel := context.WithTimeout(ctx, inspector.dependencies.CollectionTimeout)
	defer cancel()

	records, err := inspector.dependencies.Radarr.ReadQueue(collectionContext)
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("read Radarr queue: %w", err)
	}
	record, err := selectCandidate(records, selection)
	if err != nil {
		return casebuilder.Assembly{}, err
	}

	torrent, found, err := inspector.dependencies.Transmission.FindTorrent(collectionContext, record.DownloadID)
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("read Transmission torrent: %w", err)
	}
	if !found {
		return casebuilder.Assembly{}, fmt.Errorf(
			"Transmission torrent for queue record %d was not found",
			record.ID,
		)
	}
	correlation := controller.CorrelateDownload(record, torrent)
	if !correlation.Eligible() {
		return casebuilder.Assembly{}, fmt.Errorf(
			"queue record %d has an ineligible download correlation: %v",
			record.ID,
			correlation.RejectionReasons,
		)
	}

	movieID := *record.MovieID
	movie, err := inspector.dependencies.Radarr.ReadMovie(collectionContext, movieID)
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("read Radarr movie: %w", err)
	}
	history, err := inspector.dependencies.Radarr.ReadHistory(collectionContext, movieID, record.DownloadID)
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("read Radarr history: %w", err)
	}
	manualImports, err := inspector.dependencies.Radarr.ReadManualImports(
		collectionContext,
		controller.RadarrManualImportQuery{
			MovieID: movieID, DownloadID: record.DownloadID, Folder: correlation.DownloadRoot,
		},
	)
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("read Radarr manual imports: %w", err)
	}
	inventory, err := inspector.dependencies.Files.Inventory(collectionContext, correlation)
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("inventory download files: %w", err)
	}
	probes, err := inspector.collectProbes(ctx, collectionContext, inventory)
	if err != nil {
		return casebuilder.Assembly{}, err
	}

	assembly, err := inspector.assemble(casebuilder.Observation{
		ObservedAt:    inspector.dependencies.Clock.Now(),
		Correlation:   correlation,
		Movie:         movie,
		History:       history,
		ManualImports: manualImports,
		Inventory:     inventory,
		Probes:        probes,
	})
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("assemble repair case: %w", err)
	}
	return assembly, nil
}

func selectCandidate(
	records []controller.RadarrQueueRecord,
	selection Selection,
) (controller.RadarrQueueRecord, error) {
	assessments := controller.ClassifyRepairCandidates(records)
	if selection.QueueID != 0 {
		for _, assessment := range assessments {
			if assessment.Record.ID != selection.QueueID {
				continue
			}
			if !assessment.Eligible() {
				return controller.RadarrQueueRecord{}, fmt.Errorf(
					"Radarr queue record %d is ineligible: %v",
					selection.QueueID,
					assessment.RejectionReasons,
				)
			}
			return assessment.Record, nil
		}
		return controller.RadarrQueueRecord{}, fmt.Errorf(
			"Radarr queue record %d was not found",
			selection.QueueID,
		)
	}

	eligible := make([]controller.RadarrQueueRecord, 0, len(assessments))
	for _, assessment := range assessments {
		if assessment.Eligible() {
			eligible = append(eligible, assessment.Record)
		}
	}
	switch len(eligible) {
	case 0:
		return controller.RadarrQueueRecord{}, fmt.Errorf("Radarr queue has no eligible repair candidates")
	case 1:
		return eligible[0], nil
	default:
		return controller.RadarrQueueRecord{}, fmt.Errorf(
			"Radarr queue has %d eligible repair candidates; select a queue ID",
			len(eligible),
		)
	}
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

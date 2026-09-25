package lidarrrepair

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

type Lidarr interface {
	ReadQueue(context.Context) ([]lidarr.QueueRecord, error)
	RecoverAlbumIdentity(context.Context, string) (lidarr.AlbumIdentity, bool, error)
	ReadAlbum(context.Context, int64) (lidarr.Album, error)
	ReadReleaseTracks(context.Context, int64, int64) ([]lidarr.Track, error)
	ReadManualImports(context.Context, lidarr.ManualImportQuery) ([]lidarr.ManualImport, error)
}

type Worker interface {
	PathResolver
	MaterializeTarAudio(
		context.Context,
		string,
		fileidentity.Snapshot,
		string,
	) (materialize.Success, error)
	MaterializeRARAudio(
		context.Context,
		string,
		fileidentity.Snapshot,
		string,
	) (materialize.Success, error)
	MaterializeDirectoryAudio(context.Context, string, string) (materialize.Success, error)
}

type Planner interface {
	PlanLidarr(context.Context, lidarrcontracts.Case) (lidarrcontracts.Decision, error)
}

type Report struct {
	Observed     int
	Candidates   int
	Planned      int
	Cached       int
	Deferred     int
	NoRepair     int
	PlannedCases []Record
}

type Evidence struct {
	Queue             lidarr.QueueRecord
	SourceKind        SourceKind
	SourcePath        string
	SourceFingerprint string
	WorkspaceRoot     string
	Case              lidarrcontracts.Case
	Bindings          []ImportBinding
	Recovered         bool
}

type Runner struct {
	lidarr   Lidarr
	worker   Worker
	store    *Store
	now      func() time.Time
	planning *planningrunner.Runner[
		Record,
		lidarrcontracts.Decision,
		planningrunner.Failure,
	]
}

type lidarrPlanningResult = planningrunner.Result[
	Record,
	lidarrcontracts.Decision,
	planningrunner.Failure,
]

var errNoArchive = errors.New("download contains no supported archive")

type archiveKind uint8

const (
	archiveTar archiveKind = iota + 1
	archiveRAR
)

const (
	initialPlanningBackoff = 5 * time.Minute
	maximumPlanningBackoff = 6 * time.Hour
)

func NewRunner(client Lidarr, worker Worker, planner Planner, store *Store) (*Runner, error) {
	if client == nil || worker == nil || planner == nil || store == nil {
		return nil, fmt.Errorf("Lidarr shadow runner dependencies are incomplete")
	}
	runner := &Runner{
		lidarr: client, worker: worker, store: store, now: time.Now,
	}
	planning, err := planningrunner.New(planningrunner.Dependencies[
		Record,
		lidarrcontracts.Decision,
		planningrunner.Failure,
	]{
		Store: store,
		Plan: func(ctx context.Context, record Record) (lidarrcontracts.Decision, error) {
			repairCase, err := lidarrcontracts.DecodeCase(record.Case)
			if err != nil {
				return lidarrcontracts.Decision{}, err
			}
			decision, err := planner.PlanLidarr(ctx, repairCase)
			if err != nil {
				return lidarrcontracts.Decision{}, err
			}
			if err := ValidateDecision(repairCase, decision); err != nil {
				return lidarrcontracts.Decision{}, &planningrunner.InvalidResultError{Err: err}
			}
			return decision, nil
		},
		Clock: runnerClock{runner: runner},
		CaseID: func(record Record) string {
			caseID, _ := recordCaseID(record)
			return caseID
		},
		DecisionCaseID:  func(decision lidarrcontracts.Decision) string { return decision.CaseID() },
		Superseded:      func(Record) bool { return false },
		ClassifyFailure: planningrunner.ClassifyFailure,
		Backoff: planningrunner.Backoff{
			Initial: initialPlanningBackoff,
			Maximum: maximumPlanningBackoff,
		},
	})
	if err != nil {
		return nil, err
	}
	runner.planning = planning
	return runner, nil
}

func (runner *Runner) Run(ctx context.Context) (Report, error) {
	records, err := runner.lidarr.ReadQueue(ctx)
	if err != nil {
		return Report{}, fmt.Errorf("observe Lidarr queue: %w", err)
	}
	report := Report{Observed: len(records)}
	var failures []error
	for _, queue := range records {
		queue, err = runner.recoverQueueIdentity(ctx, queue)
		if err != nil {
			failures = append(failures, fmt.Errorf("queue %d: %w", queue.ID, err))
			continue
		}
		if !eligibleQueue(queue) {
			continue
		}
		candidate, result, err := runner.processQueue(ctx, queue)
		if candidate {
			report.Candidates++
		}
		if err != nil {
			failures = append(failures, fmt.Errorf("queue %d: %w", queue.ID, err))
			continue
		}
		if !candidate {
			continue
		}
		switch result.Outcome {
		case planningrunner.Decided:
			report.Planned++
		case planningrunner.AlreadyDecided:
			report.Cached++
		case planningrunner.Deferred:
			report.Deferred++
		}
		if result.Outcome == planningrunner.Decided ||
			result.Outcome == planningrunner.AlreadyDecided {
			decision := result.Planned.Decision
			record := result.Planned.Case
			decisionData, encodeErr := lidarrcontracts.EncodeDecision(decision)
			if encodeErr != nil {
				failures = append(failures, fmt.Errorf("queue %d: %w", queue.ID, encodeErr))
				continue
			}
			record.Decision = decisionData
			report.PlannedCases = append(report.PlannedCases, record)
		}
		if result.Planned.Decision.Kind == lidarrcontracts.ActionNoRepair {
			report.NoRepair++
		}
	}
	return report, errors.Join(failures...)
}

func (runner *Runner) processQueue(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (bool, lidarrPlanningResult, error) {
	archivePath, snapshot, kind, err := findArchive(queue.OutputPath)
	if err == nil {
		result, processErr := runner.processArchive(ctx, queue, archivePath, snapshot, kind)
		return true, result, processErr
	}
	if !errors.Is(err, errNoArchive) {
		if errors.Is(err, os.ErrNotExist) {
			planned, found, readErr := runner.store.Get(queue.ID)
			if readErr != nil || !found {
				return found, lidarrPlanningResult{}, readErr
			}
			evidence, buildErr := runner.buildStoredEvidence(ctx, queue, planned)
			if buildErr != nil {
				return true, lidarrPlanningResult{}, buildErr
			}
			result, planErr := runner.planEvidence(ctx, evidence)
			return true, result, planErr
		}
		return true, lidarrPlanningResult{}, fmt.Errorf("discover source: %w", err)
	}

	materialized, err := runner.worker.MaterializeDirectoryAudio(
		ctx, queue.OutputPath, directoryWorkspaceID(queue.ID, queue.OutputPath),
	)
	if materialize.IsNoSupportedAudio(err) {
		return false, lidarrPlanningResult{}, nil
	}
	if err != nil {
		return true, lidarrPlanningResult{}, fmt.Errorf(
			"materialize directory evidence: %w", err,
		)
	}
	result, err := runner.processMaterialized(
		ctx, queue, SourceDirectoryAudio, queue.OutputPath, materialized,
	)
	return true, result, err
}

func (runner *Runner) processArchive(
	ctx context.Context,
	queue lidarr.QueueRecord,
	archivePath string,
	snapshot fileidentity.Snapshot,
	kind archiveKind,
) (lidarrPlanningResult, error) {
	fingerprint := snapshot.StableFingerprint()
	var materialized materialize.Success
	var err error
	sourceKind := SourceTarAudio
	switch kind {
	case archiveTar:
		materialized, err = runner.worker.MaterializeTarAudio(
			ctx, archivePath, snapshot, workspaceID(queue.ID, fingerprint),
		)
	case archiveRAR:
		sourceKind = SourceRARAudio
		materialized, err = runner.worker.MaterializeRARAudio(
			ctx, archivePath, snapshot, workspaceID(queue.ID, fingerprint),
		)
	default:
		return lidarrPlanningResult{}, fmt.Errorf("unsupported archive kind")
	}
	if err != nil {
		return lidarrPlanningResult{}, fmt.Errorf("materialize archive evidence: %w", err)
	}
	return runner.processMaterialized(ctx, queue, sourceKind, archivePath, materialized)
}

func (runner *Runner) processMaterialized(
	ctx context.Context,
	queue lidarr.QueueRecord,
	sourceKind SourceKind,
	sourcePath string,
	materialized materialize.Success,
) (lidarrPlanningResult, error) {
	if err := validateMaterializedSource(sourceKind, materialized); err != nil {
		return lidarrPlanningResult{}, err
	}
	evidence, err := runner.assembleMaterializedEvidence(
		ctx, queue, sourceKind, sourcePath, materialized,
	)
	if err != nil {
		return lidarrPlanningResult{}, err
	}
	return runner.planEvidence(ctx, evidence)
}

func (runner *Runner) planEvidence(
	ctx context.Context,
	evidence Evidence,
) (lidarrPlanningResult, error) {
	caseData, err := lidarrcontracts.EncodeCase(evidence.Case)
	if err != nil {
		return lidarrPlanningResult{}, err
	}
	result, err := runner.planning.Process(ctx, Record{
		Version: stateVersion, QueueID: evidence.Queue.ID, SourceKind: evidence.SourceKind,
		SourcePath: evidence.SourcePath, SourceFingerprint: evidence.SourceFingerprint,
		WorkspaceRoot: evidence.WorkspaceRoot,
		Case:          caseData, Bindings: evidence.Bindings,
	})
	if err != nil {
		return result, fmt.Errorf("plan complete case: %w", err)
	}
	return result, nil
}

func (runner *Runner) BuildCurrentEvidence(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (Evidence, error) {
	var err error
	queue, err = runner.recoverQueueIdentity(ctx, queue)
	if err != nil {
		return Evidence{}, err
	}
	if !eligibleQueue(queue) {
		return Evidence{}, fmt.Errorf("Lidarr queue item is not eligible for repair")
	}
	archivePath, snapshot, kind, err := findArchive(queue.OutputPath)
	if err == nil {
		return runner.buildArchiveEvidence(ctx, queue, archivePath, snapshot, kind)
	}
	if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, errNoArchive) {
		return Evidence{}, fmt.Errorf("discover archive: %w", err)
	}
	if errors.Is(err, errNoArchive) {
		evidence, directoryErr := runner.buildDirectoryEvidence(ctx, queue)
		if directoryErr == nil {
			return evidence, nil
		}
		if !materialize.IsNoSupportedAudio(directoryErr) {
			return Evidence{}, directoryErr
		}
	}
	planned, found, getErr := runner.store.Get(queue.ID)
	if getErr != nil {
		return Evidence{}, getErr
	}
	if !found {
		return Evidence{}, fmt.Errorf("discover archive: %w", err)
	}
	return runner.buildStoredEvidence(ctx, queue, planned)
}

func (runner *Runner) recoverQueueIdentity(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (lidarr.QueueRecord, error) {
	if queue.AlbumID != nil && queue.ArtistID != nil {
		return queue, nil
	}
	if !eligibleQueueWithoutIdentity(queue) {
		return queue, nil
	}
	identity, found, err := runner.lidarr.RecoverAlbumIdentity(ctx, queue.DownloadID)
	if err != nil {
		return queue, fmt.Errorf("recover Lidarr album identity: %w", err)
	}
	if !found {
		return queue, nil
	}
	if queue.AlbumID != nil && *queue.AlbumID != identity.AlbumID {
		return queue, fmt.Errorf("recovered Lidarr album identity conflicts with queue")
	}
	if queue.ArtistID != nil && *queue.ArtistID != identity.ArtistID {
		return queue, fmt.Errorf("recovered Lidarr artist identity conflicts with queue")
	}
	queue.AlbumID = &identity.AlbumID
	queue.ArtistID = &identity.ArtistID
	return queue, nil
}

func (runner *Runner) buildArchiveEvidence(
	ctx context.Context,
	queue lidarr.QueueRecord,
	archivePath string,
	snapshot fileidentity.Snapshot,
	kind archiveKind,
) (Evidence, error) {
	fingerprint := snapshot.StableFingerprint()
	var materialized materialize.Success
	var err error
	sourceKind := SourceTarAudio
	switch kind {
	case archiveTar:
		materialized, err = runner.worker.MaterializeTarAudio(
			ctx, archivePath, snapshot, workspaceID(queue.ID, fingerprint),
		)
	case archiveRAR:
		sourceKind = SourceRARAudio
		materialized, err = runner.worker.MaterializeRARAudio(
			ctx, archivePath, snapshot, workspaceID(queue.ID, fingerprint),
		)
	default:
		return Evidence{}, fmt.Errorf("unsupported archive kind")
	}
	if err != nil {
		return Evidence{}, fmt.Errorf("materialize archive evidence: %w", err)
	}
	return runner.assembleMaterializedEvidence(
		ctx, queue, sourceKind, archivePath, materialized,
	)
}

func (runner *Runner) buildDirectoryEvidence(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (Evidence, error) {
	materialized, err := runner.worker.MaterializeDirectoryAudio(
		ctx, queue.OutputPath, directoryWorkspaceID(queue.ID, queue.OutputPath),
	)
	if err != nil {
		return Evidence{}, fmt.Errorf("materialize directory evidence: %w", err)
	}
	return runner.assembleMaterializedEvidence(
		ctx, queue, SourceDirectoryAudio, queue.OutputPath, materialized,
	)
}

func (runner *Runner) assembleMaterializedEvidence(
	ctx context.Context,
	queue lidarr.QueueRecord,
	sourceKind SourceKind,
	sourcePath string,
	materialized materialize.Success,
) (Evidence, error) {
	if err := validateMaterializedSource(sourceKind, materialized); err != nil {
		return Evidence{}, err
	}
	root, err := workspaceRoot(runner.worker, materialized)
	if err != nil {
		return Evidence{}, fmt.Errorf("resolve materialized workspace: %w", err)
	}
	album, tracks, err := runner.readCatalog(ctx, queue)
	if err != nil {
		return Evidence{}, err
	}
	manualImports, err := runner.lidarr.ReadManualImports(ctx, lidarr.ManualImportQuery{
		Folder: root, ArtistID: *queue.ArtistID,
	})
	if err != nil {
		return Evidence{}, fmt.Errorf("read manual imports: %w", err)
	}
	repairCase, bindings, err := Assemble(
		runner.now(), queue, album, tracks, materialized, manualImports, runner.worker,
	)
	if err != nil {
		return Evidence{}, fmt.Errorf("assemble complete case: %w", err)
	}
	return Evidence{
		Queue: queue, SourceKind: sourceKind, SourcePath: sourcePath,
		SourceFingerprint: materialized.SourceFingerprint,
		WorkspaceRoot:     root, Case: repairCase, Bindings: bindings,
	}, nil
}

func validateMaterializedSource(sourceKind SourceKind, materialized materialize.Success) error {
	expected := materialize.OperationMaterializeTar
	if sourceKind == SourceDirectoryAudio {
		expected = materialize.OperationMaterializeDirectory
	} else if sourceKind == SourceRARAudio {
		expected = materialize.OperationMaterializeRAR
	}
	if materialized.Operation != expected {
		return fmt.Errorf("worker returned the wrong materialization operation")
	}
	return nil
}

func (runner *Runner) buildStoredEvidence(
	ctx context.Context,
	queue lidarr.QueueRecord,
	planned Record,
) (Evidence, error) {
	plannedCase, err := lidarrcontracts.DecodeCase(planned.Case)
	if err != nil {
		return Evidence{}, fmt.Errorf("decode stored case: %w", err)
	}
	if planned.QueueID != queue.ID || plannedCase.Queue.QueueID != queue.ID ||
		queue.AlbumID == nil || plannedCase.Album.AlbumID != *queue.AlbumID ||
		queue.ArtistID == nil || plannedCase.Album.ArtistID != *queue.ArtistID {
		return Evidence{}, fmt.Errorf("stored Lidarr case does not match the current queue item")
	}
	for _, binding := range planned.Bindings {
		if binding.DownloadID != queue.DownloadID {
			return Evidence{}, fmt.Errorf("stored Lidarr binding changed download identity")
		}
	}
	if err := verifyStoredArtifacts(
		planned.WorkspaceRoot, plannedCase.Artifacts, planned.Bindings,
	); err != nil {
		return Evidence{}, err
	}
	album, tracks, err := runner.readCatalog(ctx, queue)
	if err != nil {
		return Evidence{}, err
	}
	manualImports, err := runner.lidarr.ReadManualImports(ctx, lidarr.ManualImportQuery{
		Folder: planned.WorkspaceRoot, ArtistID: *queue.ArtistID,
	})
	if err != nil {
		return Evidence{}, fmt.Errorf("reassess stored manual imports: %w", err)
	}
	repairCase, bindings, err := AssembleStored(
		runner.now(), queue, album, tracks, planned.WorkspaceRoot,
		plannedCase.Artifacts, manualImports,
	)
	if err != nil {
		return Evidence{}, fmt.Errorf("assemble stored case: %w", err)
	}
	return Evidence{
		Queue: queue, SourceKind: planned.SourceKind, SourcePath: planned.SourcePath,
		SourceFingerprint: planned.SourceFingerprint,
		WorkspaceRoot:     planned.WorkspaceRoot, Case: repairCase,
		Bindings: bindings, Recovered: true,
	}, nil
}

func (runner *Runner) readCatalog(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (lidarr.Album, []lidarr.Track, error) {
	album, err := runner.lidarr.ReadAlbum(ctx, *queue.AlbumID)
	if err != nil {
		return lidarr.Album{}, nil, fmt.Errorf("read album: %w", err)
	}
	var tracks []lidarr.Track
	for _, release := range album.Releases {
		releaseTracks, readErr := runner.lidarr.ReadReleaseTracks(ctx, album.ID, release.ID)
		if readErr != nil {
			return lidarr.Album{}, nil, fmt.Errorf(
				"read release %d tracks: %w", release.ID, readErr,
			)
		}
		tracks = append(tracks, releaseTracks...)
	}
	return album, tracks, nil
}

func eligibleQueue(queue lidarr.QueueRecord) bool {
	return queue.AlbumID != nil && queue.ArtistID != nil &&
		eligibleQueueWithoutIdentity(queue)
}

func eligibleQueueWithoutIdentity(queue lidarr.QueueRecord) bool {
	return queue.OutputPath != "" && queue.DownloadID != "" &&
		queue.Status == "completed" && queue.TrackedDownloadStatus == "warning"
}

func findArchive(outputPath string) (string, fileidentity.Snapshot, archiveKind, error) {
	if outputPath == "" || !filepath.IsAbs(outputPath) || filepath.Clean(outputPath) != outputPath {
		return "", fileidentity.Snapshot{}, 0, fmt.Errorf("download output path is invalid")
	}
	rootInfo, err := os.Lstat(outputPath)
	if err != nil {
		return "", fileidentity.Snapshot{}, 0, fmt.Errorf("inspect download output: %w", err)
	}
	if !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 {
		return "", fileidentity.Snapshot{}, 0, fmt.Errorf("download output is not a regular directory")
	}
	entries, err := os.ReadDir(outputPath)
	if err != nil {
		return "", fileidentity.Snapshot{}, 0, fmt.Errorf("read download output: %w", err)
	}
	var archivePath string
	var archiveInfo os.FileInfo
	var kind archiveKind
	for _, entry := range entries {
		var candidateKind archiveKind
		switch strings.ToLower(filepath.Ext(entry.Name())) {
		case ".tar":
			candidateKind = archiveTar
		case ".rar":
			candidateKind = archiveRAR
		default:
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return "", fileidentity.Snapshot{}, 0, fmt.Errorf("inspect archive candidate: %w", err)
		}
		if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return "", fileidentity.Snapshot{}, 0, fmt.Errorf("archive candidate is not a regular file")
		}
		if archivePath != "" {
			return "", fileidentity.Snapshot{}, 0, fmt.Errorf(
				"download contains multiple supported archives",
			)
		}
		archivePath = filepath.Join(outputPath, entry.Name())
		archiveInfo = info
		kind = candidateKind
	}
	if archivePath == "" {
		return "", fileidentity.Snapshot{}, 0, errNoArchive
	}
	snapshot, err := fileidentity.FromFileInfo(archiveInfo)
	if err != nil {
		return "", fileidentity.Snapshot{}, 0, err
	}
	return archivePath, snapshot, kind, nil
}

type runnerClock struct {
	runner *Runner
}

func (clock runnerClock) Now() time.Time {
	return clock.runner.now()
}

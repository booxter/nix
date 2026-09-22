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
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

type Lidarr interface {
	ReadQueue(context.Context) ([]lidarr.QueueRecord, error)
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
}

type Planner interface {
	PlanLidarr(context.Context, lidarrcontracts.Case) (lidarrcontracts.Decision, error)
}

type Report struct {
	Observed   int
	Candidates int
	Planned    int
	Cached     int
	NoRepair   int
}

type Evidence struct {
	Queue              lidarr.QueueRecord
	ArchivePath        string
	ArchiveFingerprint string
	WorkspaceRoot      string
	Case               lidarrcontracts.Case
	Bindings           []ImportBinding
	Recovered          bool
}

type Runner struct {
	lidarr  Lidarr
	worker  Worker
	planner Planner
	store   *Store
	now     func() time.Time
}

var errNoTarArchive = errors.New("download contains no tar archive")

func NewRunner(client Lidarr, worker Worker, planner Planner, store *Store) (*Runner, error) {
	if client == nil || worker == nil || planner == nil || store == nil {
		return nil, fmt.Errorf("Lidarr shadow runner dependencies are incomplete")
	}
	return &Runner{
		lidarr: client, worker: worker, planner: planner, store: store, now: time.Now,
	}, nil
}

func (runner *Runner) Run(ctx context.Context) (Report, error) {
	records, err := runner.lidarr.ReadQueue(ctx)
	if err != nil {
		return Report{}, fmt.Errorf("observe Lidarr queue: %w", err)
	}
	report := Report{Observed: len(records)}
	var failures []error
	for _, queue := range records {
		if !eligibleQueue(queue) {
			continue
		}
		archivePath, snapshot, err := findArchive(queue.OutputPath)
		if errors.Is(err, errNoTarArchive) {
			decision, found, cachedErr := runner.cachedDecision(queue.ID)
			if cachedErr != nil {
				failures = append(failures, fmt.Errorf("queue %d: %w", queue.ID, cachedErr))
				continue
			}
			if !found {
				continue
			}
			report.Candidates++
			report.Cached++
			if decision.Kind == lidarrcontracts.ActionNoRepair {
				report.NoRepair++
			}
			continue
		}
		report.Candidates++
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				decision, found, cachedErr := runner.cachedDecision(queue.ID)
				if cachedErr != nil {
					failures = append(failures, fmt.Errorf("queue %d: %w", queue.ID, cachedErr))
					continue
				}
				if found {
					report.Cached++
					if decision.Kind == lidarrcontracts.ActionNoRepair {
						report.NoRepair++
					}
					continue
				}
			}
			failures = append(failures, fmt.Errorf("queue %d: discover tar archive: %w", queue.ID, err))
			continue
		}
		cached, decision, err := runner.process(ctx, queue, archivePath, snapshot)
		if err != nil {
			failures = append(failures, fmt.Errorf("queue %d: %w", queue.ID, err))
			continue
		}
		if cached {
			report.Cached++
		} else {
			report.Planned++
		}
		if decision.Kind == lidarrcontracts.ActionNoRepair {
			report.NoRepair++
		}
	}
	return report, errors.Join(failures...)
}

func (runner *Runner) cachedDecision(
	queueID int64,
) (lidarrcontracts.Decision, bool, error) {
	record, found, err := runner.store.Get(queueID)
	if err != nil || !found {
		return lidarrcontracts.Decision{}, found, err
	}
	decision, err := lidarrcontracts.DecodeDecision(record.Decision)
	return decision, true, err
}

func (runner *Runner) process(
	ctx context.Context,
	queue lidarr.QueueRecord,
	archivePath string,
	snapshot fileidentity.Snapshot,
) (bool, lidarrcontracts.Decision, error) {
	fingerprint := snapshot.Fingerprint()
	previous, found, err := runner.store.Get(queue.ID)
	if err != nil {
		return false, lidarrcontracts.Decision{}, err
	}
	if found && previous.ArchivePath == archivePath && previous.ArchiveFingerprint == fingerprint {
		decision, err := lidarrcontracts.DecodeDecision(previous.Decision)
		return true, decision, err
	}

	evidence, err := runner.buildEvidence(ctx, queue, archivePath, snapshot)
	if err != nil {
		return false, lidarrcontracts.Decision{}, err
	}
	decision, err := runner.planner.PlanLidarr(ctx, evidence.Case)
	if err != nil {
		return false, lidarrcontracts.Decision{}, fmt.Errorf("plan complete case: %w", err)
	}
	if err := ValidateDecision(evidence.Case, decision); err != nil {
		return false, lidarrcontracts.Decision{}, fmt.Errorf("validate planned repair: %w", err)
	}
	caseData, err := lidarrcontracts.EncodeCase(evidence.Case)
	if err != nil {
		return false, lidarrcontracts.Decision{}, err
	}
	decisionData, err := lidarrcontracts.EncodeDecision(decision)
	if err != nil {
		return false, lidarrcontracts.Decision{}, err
	}
	if err := runner.store.Put(Record{
		Version: stateVersion, QueueID: queue.ID, ArchivePath: archivePath,
		ArchiveFingerprint: fingerprint, WorkspaceRoot: evidence.WorkspaceRoot,
		Case: caseData, Decision: decisionData, Bindings: evidence.Bindings,
	}); err != nil {
		return false, lidarrcontracts.Decision{}, fmt.Errorf("store shadow decision: %w", err)
	}
	return false, decision, nil
}

func (runner *Runner) BuildCurrentEvidence(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (Evidence, error) {
	if !eligibleQueue(queue) {
		return Evidence{}, fmt.Errorf("Lidarr queue item is not eligible for repair")
	}
	archivePath, snapshot, err := findArchive(queue.OutputPath)
	if err == nil {
		return runner.buildEvidence(ctx, queue, archivePath, snapshot)
	}
	if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, errNoTarArchive) {
		return Evidence{}, fmt.Errorf("discover tar archive: %w", err)
	}
	planned, found, getErr := runner.store.Get(queue.ID)
	if getErr != nil {
		return Evidence{}, getErr
	}
	if !found {
		return Evidence{}, fmt.Errorf("discover tar archive: %w", err)
	}
	return runner.buildStoredEvidence(ctx, queue, planned)
}

func (runner *Runner) buildEvidence(
	ctx context.Context,
	queue lidarr.QueueRecord,
	archivePath string,
	snapshot fileidentity.Snapshot,
) (Evidence, error) {
	fingerprint := snapshot.Fingerprint()
	materialized, err := runner.worker.MaterializeTarAudio(
		ctx, archivePath, snapshot, workspaceID(queue.ID, fingerprint),
	)
	if err != nil {
		return Evidence{}, fmt.Errorf("materialize archive evidence: %w", err)
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
		Queue: queue, ArchivePath: archivePath, ArchiveFingerprint: fingerprint,
		WorkspaceRoot: root, Case: repairCase, Bindings: bindings,
	}, nil
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
		Queue: queue, ArchivePath: planned.ArchivePath,
		ArchiveFingerprint: planned.ArchiveFingerprint,
		WorkspaceRoot:      planned.WorkspaceRoot, Case: repairCase,
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
	if queue.AlbumID == nil || queue.ArtistID == nil || queue.OutputPath == "" ||
		queue.DownloadID == "" || queue.Status != "completed" ||
		queue.TrackedDownloadStatus != "warning" {
		return false
	}
	return true
}

func findArchive(outputPath string) (string, fileidentity.Snapshot, error) {
	if outputPath == "" || !filepath.IsAbs(outputPath) || filepath.Clean(outputPath) != outputPath {
		return "", fileidentity.Snapshot{}, fmt.Errorf("download output path is invalid")
	}
	rootInfo, err := os.Lstat(outputPath)
	if err != nil {
		return "", fileidentity.Snapshot{}, fmt.Errorf("inspect download output: %w", err)
	}
	if !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 {
		return "", fileidentity.Snapshot{}, fmt.Errorf("download output is not a regular directory")
	}
	entries, err := os.ReadDir(outputPath)
	if err != nil {
		return "", fileidentity.Snapshot{}, fmt.Errorf("read download output: %w", err)
	}
	var archivePath string
	var archiveInfo os.FileInfo
	for _, entry := range entries {
		if !strings.EqualFold(filepath.Ext(entry.Name()), ".tar") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return "", fileidentity.Snapshot{}, fmt.Errorf("inspect archive candidate: %w", err)
		}
		if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return "", fileidentity.Snapshot{}, fmt.Errorf("archive candidate is not a regular file")
		}
		if archivePath != "" {
			return "", fileidentity.Snapshot{}, fmt.Errorf("download contains multiple tar archives")
		}
		archivePath = filepath.Join(outputPath, entry.Name())
		archiveInfo = info
	}
	if archivePath == "" {
		return "", fileidentity.Snapshot{}, errNoTarArchive
	}
	snapshot, err := fileidentity.FromFileInfo(archiveInfo)
	if err != nil {
		return "", fileidentity.Snapshot{}, err
	}
	return archivePath, snapshot, nil
}

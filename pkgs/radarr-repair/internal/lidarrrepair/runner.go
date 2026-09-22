package lidarrrepair

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/fileidentity"
	"github.com/booxter/nix-config/radarr-repair/internal/lidarr"
	"github.com/booxter/nix-config/radarr-repair/lidarrcontracts"
	"github.com/booxter/nix-config/radarr-repair/worker/materialize"
)

type Lidarr interface {
	ReadQueue(context.Context) ([]lidarr.QueueRecord, error)
	ReadAlbum(context.Context, int64) (lidarr.Album, error)
	ReadTracks(context.Context, int64) ([]lidarr.Track, error)
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
			continue
		}
		report.Candidates++
		if err != nil {
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

	materialized, err := runner.worker.MaterializeTarAudio(
		ctx, archivePath, snapshot, workspaceID(queue.ID, fingerprint),
	)
	if err != nil {
		return false, lidarrcontracts.Decision{}, fmt.Errorf("materialize archive evidence: %w", err)
	}
	root, err := workspaceRoot(runner.worker, materialized)
	if err != nil {
		return false, lidarrcontracts.Decision{}, fmt.Errorf("resolve materialized workspace: %w", err)
	}
	album, err := runner.lidarr.ReadAlbum(ctx, *queue.AlbumID)
	if err != nil {
		return false, lidarrcontracts.Decision{}, fmt.Errorf("read album: %w", err)
	}
	tracks, err := runner.lidarr.ReadTracks(ctx, *queue.AlbumID)
	if err != nil {
		return false, lidarrcontracts.Decision{}, fmt.Errorf("read tracks: %w", err)
	}
	manualImports, err := runner.lidarr.ReadManualImports(ctx, lidarr.ManualImportQuery{
		Folder: root, ArtistID: *queue.ArtistID,
	})
	if err != nil {
		return false, lidarrcontracts.Decision{}, fmt.Errorf("read manual imports: %w", err)
	}
	repairCase, bindings, err := Assemble(
		runner.now(), queue, album, tracks, materialized, manualImports, runner.worker,
	)
	if err != nil {
		return false, lidarrcontracts.Decision{}, fmt.Errorf("assemble complete case: %w", err)
	}
	decision, err := runner.planner.PlanLidarr(ctx, repairCase)
	if err != nil {
		return false, lidarrcontracts.Decision{}, fmt.Errorf("plan complete case: %w", err)
	}
	if err := ValidateDecision(repairCase, decision); err != nil {
		return false, lidarrcontracts.Decision{}, fmt.Errorf("validate planned repair: %w", err)
	}
	caseData, err := lidarrcontracts.EncodeCase(repairCase)
	if err != nil {
		return false, lidarrcontracts.Decision{}, err
	}
	decisionData, err := lidarrcontracts.EncodeDecision(decision)
	if err != nil {
		return false, lidarrcontracts.Decision{}, err
	}
	if err := runner.store.Put(Record{
		Version: stateVersion, QueueID: queue.ID, ArchivePath: archivePath,
		ArchiveFingerprint: fingerprint, WorkspaceRoot: root,
		Case: caseData, Decision: decisionData, Bindings: bindings,
	}); err != nil {
		return false, lidarrcontracts.Decision{}, fmt.Errorf("store shadow decision: %w", err)
	}
	return false, decision, nil
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

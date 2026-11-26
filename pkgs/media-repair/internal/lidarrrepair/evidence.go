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
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
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

type Planner interface {
	PlanLidarr(context.Context, lidarrcontracts.Case, planning.Options) (lidarrcontracts.Decision, error)
}

type ImportClient interface {
	RequestManualImport(context.Context, lidarr.ManualImportCommand) (servarr.Command, error)
	ReadManualImportCommand(context.Context, int64) (servarr.Command, error)
	ReadImportedTracks(context.Context, int64, string) ([]lidarr.ImportedTrack, error)
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

type EvidenceCollector struct {
	lidarr Lidarr
	worker Worker

	now func() time.Time
}

func NewEvidenceCollector(client Lidarr, worker Worker) *EvidenceCollector {
	return &EvidenceCollector{lidarr: client, worker: worker, now: time.Now}
}

var errNoArchive = errors.New("download contains no supported archive")

type archiveKind uint8

const (
	archiveTar archiveKind = iota + 1
	archiveRAR
)

func (collector *EvidenceCollector) Inspect(
	ctx context.Context,
	queue lidarr.QueueRecord,
	previous *Record,
) (Evidence, error) {
	var err error
	queue, err = collector.recoverQueueIdentity(ctx, queue)
	if err != nil {
		return Evidence{}, err
	}
	if !eligibleQueue(queue) {
		return Evidence{}, fmt.Errorf("Lidarr queue item is not eligible for repair")
	}
	archivePath, snapshot, kind, err := findArchive(queue.OutputPath)
	if err == nil {
		return collector.buildArchiveEvidence(ctx, queue, archivePath, snapshot, kind)
	}
	if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, errNoArchive) {
		return Evidence{}, fmt.Errorf("discover archive: %w", err)
	}
	if errors.Is(err, errNoArchive) {
		evidence, directoryErr := collector.buildDirectoryEvidence(ctx, queue)
		if directoryErr == nil {
			return evidence, nil
		}
		if !materialize.IsNoSupportedAudio(directoryErr) {
			return Evidence{}, directoryErr
		}
	}
	if previous == nil {
		return Evidence{}, fmt.Errorf("discover archive: %w", err)
	}

	return collector.buildStoredEvidence(ctx, queue, *previous)
}

func (collector *EvidenceCollector) recoverQueueIdentity(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (lidarr.QueueRecord, error) {
	if queue.AlbumID != nil && queue.ArtistID != nil {
		return queue, nil
	}
	if !eligibleQueueWithoutIdentity(queue) {
		return queue, nil
	}

	recovered, err := lidarr.RecoverQueueIdentity(ctx, collector.lidarr, queue)
	if err != nil {
		return queue, fmt.Errorf("recover Lidarr album identity: %w", err)
	}
	return recovered, nil
}

func (collector *EvidenceCollector) buildArchiveEvidence(
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
		materialized, err = collector.worker.MaterializeTarAudio(
			ctx, archivePath, snapshot, workspaceID(queue.ID, fingerprint),
		)
	case archiveRAR:
		sourceKind = SourceRARAudio
		materialized, err = collector.worker.MaterializeRARAudio(
			ctx, archivePath, snapshot, workspaceID(queue.ID, fingerprint),
		)
	default:
		return Evidence{}, fmt.Errorf("unsupported archive kind")
	}
	if err != nil {
		return Evidence{}, fmt.Errorf("materialize archive evidence: %w", err)
	}
	return collector.assembleMaterializedEvidence(
		ctx, queue, sourceKind, archivePath, materialized,
	)
}

func (collector *EvidenceCollector) buildDirectoryEvidence(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (Evidence, error) {
	materialized, err := collector.worker.MaterializeDirectoryAudio(
		ctx, queue.OutputPath, directoryWorkspaceID(queue.ID, queue.OutputPath),
	)
	if err != nil {
		return Evidence{}, fmt.Errorf("materialize directory evidence: %w", err)
	}
	return collector.assembleMaterializedEvidence(
		ctx, queue, SourceDirectoryAudio, queue.OutputPath, materialized,
	)
}

func (collector *EvidenceCollector) assembleMaterializedEvidence(
	ctx context.Context,
	queue lidarr.QueueRecord,
	sourceKind SourceKind,
	sourcePath string,
	materialized materialize.Success,
) (Evidence, error) {
	if err := validateMaterializedSource(sourceKind, materialized); err != nil {
		return Evidence{}, err
	}
	root, err := workspaceRoot(collector.worker, materialized)
	if err != nil {
		return Evidence{}, fmt.Errorf("resolve materialized workspace: %w", err)
	}
	album, tracks, err := collector.readCatalog(ctx, queue)
	if err != nil {
		return Evidence{}, err
	}
	manualImports, err := collector.lidarr.ReadManualImports(ctx, lidarr.ManualImportQuery{
		Folder: root, ArtistID: *queue.ArtistID,
	})
	if err != nil {
		return Evidence{}, fmt.Errorf("read manual imports: %w", err)
	}
	repairCase, bindings, err := Assemble(
		collector.now(), queue, album, tracks, materialized, manualImports, collector.worker,
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

func (collector *EvidenceCollector) buildStoredEvidence(
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
	album, tracks, err := collector.readCatalog(ctx, queue)
	if err != nil {
		return Evidence{}, err
	}
	manualImports, err := collector.lidarr.ReadManualImports(ctx, lidarr.ManualImportQuery{
		Folder: planned.WorkspaceRoot, ArtistID: *queue.ArtistID,
	})
	if err != nil {
		return Evidence{}, fmt.Errorf("reassess stored manual imports: %w", err)
	}
	repairCase, bindings, err := AssembleStored(
		collector.now(), queue, album, tracks, planned.WorkspaceRoot,
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

func (collector *EvidenceCollector) readCatalog(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (lidarr.Album, []lidarr.Track, error) {
	album, err := collector.lidarr.ReadAlbum(ctx, *queue.AlbumID)
	if err != nil {
		return lidarr.Album{}, nil, fmt.Errorf("read album: %w", err)
	}
	var tracks []lidarr.Track
	for _, release := range album.Releases {
		releaseTracks, readErr := collector.lidarr.ReadReleaseTracks(ctx, album.ID, release.ID)
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

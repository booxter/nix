package lidarrrepair

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

type Worker interface {
	ResolvePublishedPath(string, []string) (string, error)
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

// The files are in case order. Their paths are relative to root, whether
// the worker just prepared them or they were verified from a saved record.
type albumWorkspace struct {
	root        string
	files       []lidarrcontracts.Artifact
	sourceKind  SourceKind
	sourcePath  string
	fingerprint string
	recovered   bool
}

var errNoArchive = errors.New("download contains no supported archive")

type archiveKind uint8

const (
	archiveTar archiveKind = iota + 1
	archiveRAR
)

// Use the archive when present, then try loose audio. A missing source can
// fall back to a saved workspace. A broken source needs operator attention.
func (inspection albumInspection) prepareWorkspace(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (albumWorkspace, error) {
	archivePath, snapshot, kind, err := findArchive(queue.OutputPath)
	if err == nil {
		return inspection.prepareArchive(ctx, queue.ID, archivePath, snapshot, kind)
	}
	if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, errNoArchive) {
		return albumWorkspace{}, fmt.Errorf("discover archive: %w", err)
	}
	if errors.Is(err, errNoArchive) {
		workspace, directoryErr := inspection.prepareDirectory(ctx, queue)
		if !materialize.IsNoSupportedAudio(directoryErr) {
			return workspace, directoryErr
		}
	}
	if inspection.previous == nil {
		return albumWorkspace{}, fmt.Errorf("discover archive: %w", err)
	}

	return restoreWorkspace(queue, *inspection.previous)
}

func (collector *EvidenceCollector) prepareArchive(
	ctx context.Context,
	queueID int64,
	archivePath string,
	snapshot fileidentity.Snapshot,
	kind archiveKind,
) (albumWorkspace, error) {
	fingerprint := snapshot.StableFingerprint()
	var materialized materialize.Success
	var err error
	sourceKind := SourceTarAudio
	switch kind {
	case archiveTar:
		materialized, err = collector.worker.MaterializeTarAudio(
			ctx, archivePath, snapshot, workspaceID(queueID, fingerprint),
		)
	case archiveRAR:
		sourceKind = SourceRARAudio
		materialized, err = collector.worker.MaterializeRARAudio(
			ctx, archivePath, snapshot, workspaceID(queueID, fingerprint),
		)
	default:
		return albumWorkspace{}, fmt.Errorf("unsupported archive kind")
	}
	if err != nil {
		return albumWorkspace{}, fmt.Errorf("materialize archive evidence: %w", err)
	}
	return collector.workerWorkspace(sourceKind, archivePath, materialized)
}

func (collector *EvidenceCollector) prepareDirectory(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (albumWorkspace, error) {
	materialized, err := collector.worker.MaterializeDirectoryAudio(
		ctx, queue.OutputPath, directoryWorkspaceID(queue.ID, queue.OutputPath),
	)
	if err != nil {
		return albumWorkspace{}, fmt.Errorf("materialize directory evidence: %w", err)
	}
	return collector.workerWorkspace(SourceDirectoryAudio, queue.OutputPath, materialized)
}

// Check that each relative file name identifies the file published by the
// worker. Lidarr uses the full path while the planner sees the relative name.
func (collector *EvidenceCollector) workerWorkspace(
	sourceKind SourceKind,
	sourcePath string,
	materialized materialize.Success,
) (albumWorkspace, error) {
	if err := validateMaterializedSource(sourceKind, materialized); err != nil {
		return albumWorkspace{}, err
	}
	root, err := collector.worker.ResolvePublishedPath(materialized.RootID, materialized.WorkspaceComponents)
	if err != nil {
		return albumWorkspace{}, fmt.Errorf("resolve materialized workspace: %w", err)
	}
	files := make([]lidarrcontracts.Artifact, len(materialized.Artifacts))
	for i, artifact := range materialized.Artifacts {
		path, err := collector.worker.ResolvePublishedPath(materialized.RootID, artifact.PathComponents)
		if err != nil {
			return albumWorkspace{}, fmt.Errorf("resolve materialized artifact: %w", err)
		}
		relative, err := filepath.Rel(root, path)
		if err != nil || relative == "." || !filepath.IsLocal(relative) || filepath.ToSlash(relative) != artifact.RelativePath {
			return albumWorkspace{}, fmt.Errorf("published file does not match workspace path %q", artifact.RelativePath)
		}
		files[i] = contractArtifact(artifact, caseArtifactID(i))
	}
	return albumWorkspace{
		root: root, files: files, sourceKind: sourceKind, sourcePath: sourcePath,
		fingerprint: materialized.SourceFingerprint,
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

// Reuse only file facts from the saved case. They still have to belong to
// this download and match the files on disk.
func restoreWorkspace(queue lidarr.QueueRecord, planned Record) (albumWorkspace, error) {
	plannedCase, err := lidarrcontracts.DecodeCase(planned.Case)
	if err != nil {
		return albumWorkspace{}, fmt.Errorf("decode stored case: %w", err)
	}
	if planned.QueueID != queue.ID || plannedCase.Queue.QueueID != queue.ID ||
		queue.AlbumID == nil || plannedCase.Album.AlbumID != *queue.AlbumID ||
		queue.ArtistID == nil || plannedCase.Album.ArtistID != *queue.ArtistID {
		return albumWorkspace{}, fmt.Errorf("stored Lidarr case does not match the current queue item")
	}
	for _, binding := range planned.Bindings {
		if binding.DownloadID != queue.DownloadID {
			return albumWorkspace{}, fmt.Errorf("stored Lidarr binding changed download identity")
		}
	}
	if !filepath.IsAbs(planned.WorkspaceRoot) || filepath.Clean(planned.WorkspaceRoot) != planned.WorkspaceRoot {
		return albumWorkspace{}, fmt.Errorf("invalid stored Lidarr workspace path")
	}
	if err := verifyStoredArtifacts(
		planned.WorkspaceRoot, plannedCase.Artifacts, planned.Bindings,
	); err != nil {
		return albumWorkspace{}, err
	}
	return albumWorkspace{
		root: planned.WorkspaceRoot, files: plannedCase.Artifacts,
		sourceKind: planned.SourceKind, sourcePath: planned.SourcePath,
		fingerprint: planned.SourceFingerprint, recovered: true,
	}, nil
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

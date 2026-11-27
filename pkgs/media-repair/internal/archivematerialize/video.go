package archivematerialize

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"github.com/booxter/nix-config/media-repair/internal/workerclient"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

type Worker interface {
	MaterializeTarVideo(
		context.Context, string, fileidentity.Snapshot, string,
	) (materialize.Success, error)
	MaterializeRARVideo(
		context.Context, string, fileidentity.Snapshot, string,
	) (materialize.Success, error)
	ResolvePublishedPath(string, []string) (string, error)
}

type Materializer struct {
	worker Worker
}

func New(worker Worker) (*Materializer, error) {
	if worker == nil {
		return nil, fmt.Errorf("archive materializer worker is required")
	}
	return &Materializer{worker: worker}, nil
}

type archiveCandidate struct {
	path      string
	snapshot  fileidentity.Snapshot
	extension string
}

func (instance *Materializer) MaterializeVideo(
	ctx context.Context,
	queueID int64,
	inventory controller.FileInventory,
) (controller.VideoSource, bool, error) {
	if instance == nil || instance.worker == nil {
		return controller.VideoSource{}, false, fmt.Errorf("archive materializer is not configured")
	}
	if queueID <= 0 {
		return controller.VideoSource{}, false, fmt.Errorf("queue ID must be positive")
	}
	for _, assessment := range controller.ClassifyMediaFiles(inventory) {
		if assessment.ProbeCandidate() {
			return controller.VideoSource{}, false, nil
		}
	}
	paths := make(map[controller.FileID]string, len(inventory.Paths))
	for _, mapping := range inventory.Paths {
		if _, duplicate := paths[mapping.FileID]; duplicate {
			return controller.VideoSource{}, false, fmt.Errorf("archive inventory contains duplicate paths")
		}
		paths[mapping.FileID] = mapping.AbsolutePath
	}
	var candidate *archiveCandidate
	for _, file := range inventory.Files {
		if len(file.PathComponents) == 0 {
			continue
		}
		extension := strings.ToLower(filepath.Ext(file.PathComponents[len(file.PathComponents)-1]))
		if extension != ".tar" && extension != ".rar" {
			continue
		}
		path, found := paths[file.ID]
		if !found {
			return controller.VideoSource{}, false, fmt.Errorf("archive candidate has no local path")
		}
		if candidate != nil {
			return controller.VideoSource{}, true, fmt.Errorf("download contains multiple supported archives")
		}
		candidate = &archiveCandidate{path: path, snapshot: file.Fingerprint, extension: extension}
	}
	if candidate == nil {
		return controller.VideoSource{}, false, nil
	}
	workspaceID := videoWorkspaceID(queueID, candidate.snapshot.StableFingerprint())
	var result materialize.Success
	var err error
	if candidate.extension == ".tar" {
		result, err = instance.worker.MaterializeTarVideo(
			ctx, candidate.path, candidate.snapshot, workspaceID,
		)
	} else {
		result, err = instance.worker.MaterializeRARVideo(
			ctx, candidate.path, candidate.snapshot, workspaceID,
		)
	}
	if err != nil {
		return controller.VideoSource{}, true, err
	}
	return instance.sourceFromResult(result)
}

func (instance *Materializer) sourceFromResult(
	result materialize.Success,
) (controller.VideoSource, bool, error) {
	root, err := instance.worker.ResolvePublishedPath(result.RootID, result.WorkspaceComponents)
	if err != nil {
		return controller.VideoSource{}, true, fmt.Errorf("resolve materialized video workspace: %w", err)
	}
	source := controller.VideoSource{
		Root: root,
		Inventory: controller.FileInventory{
			Files: make([]controller.InventoryFile, 0, len(result.Artifacts)),
			Paths: make([]controller.FilePathMapping, 0, len(result.Artifacts)),
		},
		ExistingProbes: make([]controller.FileProbe, 0, len(result.Artifacts)),
	}
	for _, artifact := range result.Artifacts {
		absolute, err := instance.worker.ResolvePublishedPath(result.RootID, artifact.PathComponents)
		if err != nil {
			return controller.VideoSource{}, true, fmt.Errorf("resolve materialized video artifact: %w", err)
		}
		info, err := os.Lstat(absolute)
		if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return controller.VideoSource{}, true, fmt.Errorf("materialized video artifact is unavailable")
		}
		snapshot, err := fileidentity.FromFileInfo(info)
		if err != nil || snapshot.SizeBytes != artifact.SizeBytes {
			return controller.VideoSource{}, true, fmt.Errorf("materialized video artifact changed")
		}
		fileID := controller.FileID(artifact.ArtifactID)
		source.Inventory.Files = append(source.Inventory.Files, controller.InventoryFile{
			ID:             fileID,
			PathComponents: strings.Split(artifact.RelativePath, "/"),
			Fingerprint:    snapshot,
			DownloadFile: &controller.DownloadFileReference{
				LengthBytes: artifact.SizeBytes, BytesCompleted: artifact.SizeBytes, Selected: true,
			},
		})
		source.Inventory.Paths = append(source.Inventory.Paths, controller.FilePathMapping{
			FileID: fileID, AbsolutePath: absolute,
		})
		source.ExistingProbes = append(source.ExistingProbes, controller.FileProbe{
			FileID:  fileID,
			Outcome: controller.SuccessfulMediaProbe(workerclient.EvidenceFromWorker(artifact.Evidence)),
		})
	}
	if len(source.Inventory.Files) == 0 {
		return controller.VideoSource{}, true, fmt.Errorf("materialized video workspace is empty")
	}
	return source, true, nil
}

func videoWorkspaceID(queueID int64, fingerprint string) string {
	digest := sha256.Sum256([]byte(fmt.Sprintf("radarr-video\x00%d\x00%s", queueID, fingerprint)))
	return "radarr:" + hex.EncodeToString(digest[:])
}

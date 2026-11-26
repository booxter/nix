package lidarrrepair

import (
	"encoding/json"

	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"golift.io/starr"
)

type SourceKind string

const (
	SourceTarAudio       SourceKind = "tar_audio_v1"
	SourceRARAudio       SourceKind = "rar_audio_v1"
	SourceDirectoryAudio SourceKind = "directory_audio_v1"
)

type ImportBinding struct {
	ArtifactID              string         `json:"artifact_id"`
	Path                    string         `json:"path"`
	Quality                 *starr.Quality `json:"quality"`
	IndexerFlags            int            `json:"indexer_flags"`
	DownloadID              string         `json:"download_id"`
	DisableReleaseSwitching bool           `json:"disable_release_switching"`
}

type Record struct {
	QueueID           int64           `json:"queue_id"`
	SourceKind        SourceKind      `json:"source_kind"`
	SourcePath        string          `json:"source_path"`
	SourceFingerprint string          `json:"source_fingerprint"`
	WorkspaceRoot     string          `json:"workspace_root"`
	Case              json.RawMessage `json:"case"`
	Decision          json.RawMessage `json:"decision"`
	Bindings          []ImportBinding `json:"bindings"`
}

func bindingFromImport(
	artifactID string,
	item lidarr.ManualImport,
	downloadID string,
) ImportBinding {
	return ImportBinding{
		ArtifactID: artifactID, Path: item.Path, Quality: item.Quality,
		IndexerFlags: item.IndexerFlags, DownloadID: downloadID,
		DisableReleaseSwitching: item.DisableReleaseSwitching,
	}
}

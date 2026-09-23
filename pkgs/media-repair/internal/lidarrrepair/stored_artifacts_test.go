package lidarrrepair

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

func TestVerifyStoredArtifactsRequiresImmutableMatchingContent(t *testing.T) {
	t.Parallel()
	body := []byte("stored track")
	digest := sha256.Sum256(body)
	fingerprint := hex.EncodeToString(digest[:])
	workspace := filepath.Join(t.TempDir(), "workspace")
	album := filepath.Join(workspace, "album")
	if err := os.MkdirAll(album, 0o750); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(album, "01.flac")
	if err := os.WriteFile(path, body, 0o640); err != nil {
		t.Fatal(err)
	}
	artifacts := []lidarrcontracts.Artifact{{
		ArtifactID: "artifact:" + fingerprint, RelativePath: "album/01.flac",
		Fingerprint: "sha256:" + fingerprint, SizeBytes: int64(len(body)),
	}}
	bindings := []ImportBinding{{ArtifactID: artifacts[0].ArtifactID, Path: path}}
	if err := verifyStoredArtifacts(workspace, artifacts, bindings); err != nil {
		t.Fatal(err)
	}
	artifacts[0].ArtifactID = materialize.ArtifactID(
		artifacts[0].RelativePath, artifacts[0].Fingerprint,
	)
	bindings[0].ArtifactID = artifacts[0].ArtifactID
	if err := verifyStoredArtifacts(workspace, artifacts, bindings); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(path, []byte("alterx track"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := verifyStoredArtifacts(workspace, artifacts, bindings); err == nil {
		t.Fatal("changed stored artifact was accepted")
	}
}

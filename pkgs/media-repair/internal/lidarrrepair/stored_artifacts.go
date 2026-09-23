package lidarrrepair

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

func verifyStoredArtifacts(
	workspaceRoot string,
	artifacts []lidarrcontracts.Artifact,
	bindings []ImportBinding,
) error {
	_, owner, err := immutableWorkspaceEntry(workspaceRoot, true, 0, false)
	if err != nil {
		return fmt.Errorf("inspect stored Lidarr workspace: %w", err)
	}
	if len(artifacts) == 0 || len(bindings) != len(artifacts) {
		return fmt.Errorf("stored Lidarr artifacts and bindings do not match")
	}
	bindingsByArtifact := make(map[string]ImportBinding, len(bindings))
	for _, binding := range bindings {
		if _, duplicate := bindingsByArtifact[binding.ArtifactID]; duplicate {
			return fmt.Errorf("stored Lidarr binding %q is duplicated", binding.ArtifactID)
		}
		bindingsByArtifact[binding.ArtifactID] = binding
	}
	for _, artifact := range artifacts {
		binding, found := bindingsByArtifact[artifact.ArtifactID]
		if !found {
			return fmt.Errorf("stored Lidarr artifact %q has no binding", artifact.ArtifactID)
		}
		relativePath := filepath.FromSlash(artifact.RelativePath)
		if relativePath == "." || filepath.IsAbs(relativePath) ||
			filepath.Clean(relativePath) != relativePath || relativePath == ".." ||
			strings.HasPrefix(relativePath, ".."+string(filepath.Separator)) {
			return fmt.Errorf("stored Lidarr artifact %q has an unsafe path", artifact.ArtifactID)
		}
		path := filepath.Join(workspaceRoot, relativePath)
		if path != binding.Path {
			return fmt.Errorf("stored Lidarr artifact %q changed path", artifact.ArtifactID)
		}
		if err := verifyStoredArtifact(workspaceRoot, relativePath, artifact, owner); err != nil {
			return err
		}
	}
	return nil
}

func verifyStoredArtifact(
	workspaceRoot string,
	relativePath string,
	artifact lidarrcontracts.Artifact,
	owner uint32,
) error {
	components := strings.Split(relativePath, string(filepath.Separator))
	current := workspaceRoot
	for _, component := range components[:len(components)-1] {
		current = filepath.Join(current, component)
		if _, _, err := immutableWorkspaceEntry(current, true, owner, true); err != nil {
			return fmt.Errorf("inspect stored Lidarr artifact directory: %w", err)
		}
	}
	path := filepath.Join(workspaceRoot, relativePath)
	info, _, err := immutableWorkspaceEntry(path, false, owner, true)
	if err != nil {
		return fmt.Errorf("inspect stored Lidarr artifact %q: %w", artifact.ArtifactID, err)
	}
	if info.Size() != artifact.SizeBytes {
		return fmt.Errorf("stored Lidarr artifact %q changed size", artifact.ArtifactID)
	}
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open stored Lidarr artifact %q: %w", artifact.ArtifactID, err)
	}
	hash := sha256.New()
	_, copyErr := io.Copy(hash, file)
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil {
		return fmt.Errorf(
			"hash stored Lidarr artifact %q: %w", artifact.ArtifactID,
			errors.Join(copyErr, closeErr),
		)
	}
	digest := hex.EncodeToString(hash.Sum(nil))
	legacyID := "artifact:" + digest
	currentID := materialize.ArtifactID(artifact.RelativePath, artifact.Fingerprint)
	if "sha256:"+digest != artifact.Fingerprint ||
		(artifact.ArtifactID != legacyID && artifact.ArtifactID != currentID) {
		return fmt.Errorf("stored Lidarr artifact %q changed contents", artifact.ArtifactID)
	}
	return nil
}

func immutableWorkspaceEntry(
	path string,
	directory bool,
	wantedOwner uint32,
	checkOwner bool,
) (os.FileInfo, uint32, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, 0, err
	}
	if info.Mode()&os.ModeSymlink != 0 || directory != info.IsDir() ||
		(!directory && !info.Mode().IsRegular()) || info.Mode().Perm()&0o022 != 0 {
		return nil, 0, fmt.Errorf("%s is not an immutable workspace entry", path)
	}
	status, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return nil, 0, fmt.Errorf("%s has unsupported ownership metadata", path)
	}
	owner := status.Uid
	if checkOwner && owner != wantedOwner {
		return nil, 0, fmt.Errorf("%s changed owner", path)
	}
	return info, owner, nil
}

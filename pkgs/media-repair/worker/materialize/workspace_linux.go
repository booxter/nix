package materialize

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
)

const (
	workspaceDirectory = ".media-repair"
	workspaceManifest  = ".materialization.json"
	manifestVersion    = "media-repair-workspace/v3"
)

type manifest struct {
	Version           string  `json:"version"`
	SourceOperation   string  `json:"source_operation"`
	SourceFingerprint string  `json:"source_fingerprint"`
	Success           Success `json:"success"`
}

type workspace struct {
	components []string
	path       string
	partial    string
	group      int
}

// A matching manifest can be reused. New artifacts stay private until all
// source checks succeed and the manifest and files can be published together.
func openWorkspace(root string, request Request, fingerprint string) (workspace, *Success, error) {
	components := []string{workspaceDirectory, "workspaces", request.WorkspaceID}
	path := filepath.Join(append([]string{root}, components...)...)
	group, err := workspaceGroup(root)
	if err != nil {
		return workspace{}, nil, err
	}
	w := workspace{components: components, path: path, partial: path + ".partial", group: group}
	cached, err := loadWorkspace(path, request, components, fingerprint)
	if err != nil {
		if err := clearWorkspace(path); err != nil {
			return w, nil, err
		}
	} else if cached != nil {
		return w, cached, nil
	}
	return w, nil, prepareWorkspace(root, w.partial, path, group)
}

func (w workspace) publish(request Request, fingerprint string, artifacts []Artifact) Response {
	success := Success{
		SchemaVersion: SchemaVersion, RequestID: request.RequestID,
		Operation: request.Operation, RootID: request.RootID,
		SourceFingerprint: fingerprint, WorkspaceComponents: w.components, Artifacts: artifacts,
	}
	if err := writeManifest(w.partial, success); err != nil {
		_ = os.RemoveAll(w.partial)
		return request.fail("workspace_error")
	}
	if err := os.Rename(w.partial, w.path); err != nil {
		_ = os.RemoveAll(w.partial)
		return request.fail("workspace_error")
	}
	return Response{Status: "ok", Success: &success}
}

func loadWorkspace(
	workspacePath string,
	request Request,
	workspaceComponents []string,
	sourceFingerprint string,
) (*Success, error) {
	info, err := os.Lstat(workspacePath)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("completed workspace is unsafe")
	}
	data, err := os.ReadFile(filepath.Join(workspacePath, workspaceManifest))
	if err != nil {
		return nil, fmt.Errorf("read workspace manifest: %w", err)
	}
	var stored manifest
	if err := json.Unmarshal(data, &stored); err != nil {
		return nil, fmt.Errorf("decode workspace manifest: %w", err)
	}
	if stored.Version != manifestVersion || stored.SourceOperation != request.Operation ||
		stored.SourceFingerprint != sourceFingerprint ||
		stored.Success.Operation != request.Operation ||
		stored.Success.SourceFingerprint != sourceFingerprint ||
		stored.Success.RootID != request.RootID ||
		!slices.Equal(stored.Success.WorkspaceComponents, workspaceComponents) {
		return nil, fmt.Errorf("workspace manifest identity does not match request")
	}
	for _, artifact := range stored.Success.Artifacts {
		name, err := safeArchiveName(artifact.RelativePath, false)
		if err != nil || !slices.Equal(
			artifact.PathComponents,
			append(append([]string(nil), workspaceComponents...), strings.Split(name, "/")...),
		) {
			return nil, fmt.Errorf("workspace artifact identity is invalid")
		}
		info, err := os.Lstat(filepath.Join(workspacePath, filepath.FromSlash(name)))
		if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 ||
			info.Size() != artifact.SizeBytes {
			return nil, fmt.Errorf("workspace artifact is unavailable")
		}
	}
	stored.Success.RequestID = request.RequestID
	if _, err := EncodeResponse(Response{Status: "ok", Success: &stored.Success}); err != nil {
		return nil, fmt.Errorf("validate workspace manifest: %w", err)
	}
	return &stored.Success, nil
}

func writeManifest(workspacePath string, success Success) error {
	data, err := json.Marshal(manifest{
		Version: manifestVersion, SourceOperation: success.Operation,
		SourceFingerprint: success.SourceFingerprint, Success: success,
	})
	if err != nil {
		return err
	}
	path := filepath.Join(workspacePath, workspaceManifest)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

func clearWorkspace(workspacePath string) error {
	info, err := os.Lstat(workspacePath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("completed workspace is unsafe")
	}
	return os.RemoveAll(workspacePath)
}

func workspaceGroup(rootPath string) (int, error) {
	base := filepath.Join(rootPath, workspaceDirectory)
	info, err := os.Lstat(base)
	if err != nil {
		return 0, fmt.Errorf("inspect workspace base: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return 0, fmt.Errorf("workspace base is unsafe")
	}
	status, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, fmt.Errorf("workspace base has unsupported metadata")
	}
	return int(status.Gid), nil
}

func prepareWorkspace(rootPath, partialPath, completedPath string, groupID int) error {
	if _, err := workspaceGroup(rootPath); err != nil {
		return err
	}
	if err := ensureWorkspaceDirectory(filepath.Dir(partialPath), groupID); err != nil {
		return fmt.Errorf("create workspace parent: %w", err)
	}
	if _, err := os.Lstat(completedPath); err == nil {
		return fmt.Errorf("workspace already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.RemoveAll(partialPath); err != nil {
		return err
	}
	if err := os.Mkdir(partialPath, 0o750); err != nil {
		return err
	}
	if err := os.Chown(partialPath, -1, groupID); err != nil {
		return err
	}
	return os.Chmod(partialPath, 0o750)
}

func ensureWorkspaceDirectory(directory string, groupID int) error {
	if err := os.MkdirAll(directory, 0o750); err != nil {
		return err
	}
	if err := os.Chown(directory, -1, groupID); err != nil {
		return err
	}
	return os.Chmod(directory, 0o750)
}

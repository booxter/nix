package materialize

import (
	"archive/tar"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"syscall"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/worker/mediaevidence"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
)

const (
	workspaceDirectory = ".media-repair"
	workspaceManifest  = ".materialization.json"
	manifestVersion    = "media-repair-workspace/v1"
	maximumEntries     = 4096
	maximumFileBytes   = 8 << 30
	maximumTotalBytes  = 32 << 30
)

var audioExtensions = map[string]struct{}{
	".flac": {}, ".wav": {}, ".ape": {}, ".wv": {}, ".m4a": {},
	".mp3": {}, ".ogg": {}, ".opus": {},
}

type Files interface {
	Open(string, []string, string) (*os.File, error)
	Path(string) (string, error)
	Verify(*os.File, string) error
}

type Prober interface {
	Probe(context.Context, string) (controller.ProbeEvidence, error)
}

type Executor struct {
	files  Files
	prober Prober
}

type manifest struct {
	Version            string  `json:"version"`
	ArchiveFingerprint string  `json:"archive_fingerprint"`
	Success            Success `json:"success"`
}

func NewExecutor(files Files, prober Prober) (*Executor, error) {
	if files == nil || prober == nil {
		return nil, fmt.Errorf("materialization requires media access and probing")
	}
	return &Executor{files: files, prober: prober}, nil
}

func (executor *Executor) Execute(ctx context.Context, request Request) Response {
	fail := func(reason string) Response {
		return Response{Status: "failed", Failure: &Failure{
			SchemaVersion: SchemaVersion, RequestID: request.RequestID,
			Operation: OperationMaterializeTar, Reason: reason,
		}}
	}
	if err := ctx.Err(); err != nil {
		return fail("timeout")
	}
	archive, err := executor.files.Open(
		request.RootID, request.ArchiveComponents, request.ExpectedFingerprint,
	)
	if err != nil {
		return fail(reasonForError(err))
	}
	defer archive.Close()
	rootPath, err := executor.files.Path(request.RootID)
	if err != nil {
		return fail(reasonForError(err))
	}
	workspaceComponents := []string{workspaceDirectory, "workspaces", request.WorkspaceID}
	workspacePath := filepath.Join(append([]string{rootPath}, workspaceComponents...)...)
	partialPath := workspacePath + ".partial"
	groupID, err := workspaceGroup(rootPath)
	if err != nil {
		return fail("workspace_error")
	}
	if success, found, err := loadWorkspace(workspacePath, request, workspaceComponents); err != nil {
		return fail("workspace_error")
	} else if found {
		if err := executor.files.Verify(archive, request.ExpectedFingerprint); err != nil {
			return fail(reasonForError(err))
		}
		return Response{Status: "ok", Success: &success}
	}
	if err := prepareWorkspace(rootPath, partialPath, workspacePath, groupID); err != nil {
		return fail("workspace_error")
	}
	artifacts, err := executor.extractAndProbe(
		ctx, archive, partialPath, workspaceComponents, groupID,
	)
	if err != nil {
		_ = os.RemoveAll(partialPath)
		return fail(reasonForError(err))
	}
	if err := executor.files.Verify(archive, request.ExpectedFingerprint); err != nil {
		_ = os.RemoveAll(partialPath)
		return fail(reasonForError(err))
	}
	success := Success{
		SchemaVersion: SchemaVersion, RequestID: request.RequestID,
		Operation: OperationMaterializeTar, RootID: request.RootID,
		WorkspaceComponents: workspaceComponents, Artifacts: artifacts,
	}
	if err := writeManifest(partialPath, request.ExpectedFingerprint, success); err != nil {
		_ = os.RemoveAll(partialPath)
		return fail("workspace_error")
	}
	if err := os.Rename(partialPath, workspacePath); err != nil {
		_ = os.RemoveAll(partialPath)
		return fail("workspace_error")
	}
	return Response{Status: "ok", Success: &success}
}

func loadWorkspace(
	workspacePath string,
	request Request,
	workspaceComponents []string,
) (Success, bool, error) {
	info, err := os.Lstat(workspacePath)
	if errors.Is(err, os.ErrNotExist) {
		return Success{}, false, nil
	}
	if err != nil {
		return Success{}, false, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return Success{}, false, fmt.Errorf("completed workspace is unsafe")
	}
	data, err := os.ReadFile(filepath.Join(workspacePath, workspaceManifest))
	if err != nil {
		return Success{}, false, fmt.Errorf("read workspace manifest: %w", err)
	}
	var stored manifest
	if err := json.Unmarshal(data, &stored); err != nil {
		return Success{}, false, fmt.Errorf("decode workspace manifest: %w", err)
	}
	if stored.Version != manifestVersion || stored.ArchiveFingerprint != request.ExpectedFingerprint ||
		stored.Success.RootID != request.RootID ||
		!slices.Equal(stored.Success.WorkspaceComponents, workspaceComponents) {
		return Success{}, false, fmt.Errorf("workspace manifest identity does not match request")
	}
	for _, artifact := range stored.Success.Artifacts {
		name, err := safeArchiveName(artifact.RelativePath, false)
		if err != nil || !slices.Equal(
			artifact.PathComponents,
			append(append([]string(nil), workspaceComponents...), strings.Split(name, "/")...),
		) {
			return Success{}, false, fmt.Errorf("workspace artifact identity is invalid")
		}
		info, err := os.Lstat(filepath.Join(workspacePath, filepath.FromSlash(name)))
		if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 ||
			info.Size() != artifact.SizeBytes {
			return Success{}, false, fmt.Errorf("workspace artifact is unavailable")
		}
	}
	stored.Success.RequestID = request.RequestID
	if _, err := EncodeResponse(Response{Status: "ok", Success: &stored.Success}); err != nil {
		return Success{}, false, fmt.Errorf("validate workspace manifest: %w", err)
	}
	return stored.Success, true, nil
}

func writeManifest(workspacePath, archiveFingerprint string, success Success) error {
	data, err := json.Marshal(manifest{
		Version: manifestVersion, ArchiveFingerprint: archiveFingerprint, Success: success,
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

func (executor *Executor) extractAndProbe(
	ctx context.Context,
	archive *os.File,
	workspacePath string,
	workspaceComponents []string,
	groupID int,
) ([]Artifact, error) {
	reader := tar.NewReader(archive)
	entries := 0
	var totalBytes int64
	seen := make(map[string]struct{})
	artifacts := make([]Artifact, 0)
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read tar: %w", err)
		}
		entries++
		if entries > maximumEntries {
			return nil, fmt.Errorf("archive contains too many entries")
		}
		name, err := safeArchiveName(header.Name, header.Typeflag == tar.TypeDir)
		if err != nil {
			return nil, err
		}
		if _, duplicate := seen[name]; duplicate {
			return nil, fmt.Errorf("archive repeats path %q", name)
		}
		seen[name] = struct{}{}
		switch header.Typeflag {
		case tar.TypeDir:
			if err := ensureWorkspaceDirectory(
				filepath.Join(workspacePath, filepath.FromSlash(name)),
				groupID,
			); err != nil {
				return nil, err
			}
		case tar.TypeReg, tar.TypeRegA:
			if header.Size < 0 || header.Size > maximumFileBytes || totalBytes > maximumTotalBytes-header.Size {
				return nil, fmt.Errorf("archive expansion exceeds limits")
			}
			totalBytes += header.Size
			artifact, audio, err := extractFile(
				reader, workspacePath, workspaceComponents, name, header.Size, groupID,
			)
			if err != nil {
				return nil, err
			}
			if !audio {
				continue
			}
			evidence, err := executor.prober.Probe(
				ctx, filepath.Join(workspacePath, filepath.FromSlash(name)),
			)
			if err != nil {
				return nil, fmt.Errorf("probe extracted audio: %w", err)
			}
			artifact.Evidence = mediaevidence.FromProbe(evidence)
			artifacts = append(artifacts, artifact)
		default:
			return nil, fmt.Errorf("archive entry %q is not a regular file or directory", name)
		}
	}
	if len(artifacts) == 0 {
		return nil, fmt.Errorf("archive contains no supported audio")
	}
	sort.Slice(artifacts, func(left, right int) bool {
		return artifacts[left].RelativePath < artifacts[right].RelativePath
	})
	return artifacts, nil
}

func extractFile(
	reader io.Reader,
	workspacePath string,
	workspaceComponents []string,
	name string,
	size int64,
	groupID int,
) (Artifact, bool, error) {
	destination := filepath.Join(workspacePath, filepath.FromSlash(name))
	if err := ensureWorkspaceDirectory(filepath.Dir(destination), groupID); err != nil {
		return Artifact{}, false, err
	}
	output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o640)
	if err != nil {
		return Artifact{}, false, err
	}
	hash := sha256.New()
	written, copyErr := io.CopyN(io.MultiWriter(output, hash), reader, size)
	closeErr := output.Close()
	if copyErr != nil || closeErr != nil || written != size {
		return Artifact{}, false, errors.Join(copyErr, closeErr, fmt.Errorf("short archive member"))
	}
	if err := os.Chmod(destination, 0o640); err != nil {
		return Artifact{}, false, err
	}
	if err := os.Chown(destination, -1, groupID); err != nil {
		return Artifact{}, false, err
	}
	digest := hex.EncodeToString(hash.Sum(nil))
	components := append(append([]string(nil), workspaceComponents...), strings.Split(name, "/")...)
	_, audio := audioExtensions[strings.ToLower(path.Ext(name))]
	return Artifact{
		ArtifactID: "artifact:" + digest, PathComponents: components,
		RelativePath: name, SizeBytes: size, Fingerprint: "sha256:" + digest,
	}, audio, nil
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

func safeArchiveName(name string, directory bool) (string, error) {
	if directory {
		name = strings.TrimSuffix(name, "/")
	}
	if name == "" || strings.ContainsAny(name, "\\\x00") || strings.HasPrefix(name, "/") {
		return "", fmt.Errorf("archive path is unsafe")
	}
	clean := path.Clean(name)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") || clean != name {
		return "", fmt.Errorf("archive path %q is unsafe", name)
	}
	for _, component := range strings.Split(clean, "/") {
		if component == "" || component == "." || component == ".." || len(component) > 255 {
			return "", fmt.Errorf("archive path %q is unsafe", name)
		}
	}
	return clean, nil
}

func reasonForError(err error) string {
	var fileFailure *mediafile.Failure
	if errors.As(err, &fileFailure) {
		switch fileFailure.Kind {
		case mediafile.FailureUnknownRoot:
			return "unknown_root"
		case mediafile.FailureInvalidPath:
			return "invalid_path"
		case mediafile.FailureFileUnavailable:
			return "file_unavailable"
		case mediafile.FailureNotRegularFile:
			return "not_regular_file"
		case mediafile.FailureFingerprintMismatch:
			return "fingerprint_mismatch"
		}
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	return "invalid_archive"
}

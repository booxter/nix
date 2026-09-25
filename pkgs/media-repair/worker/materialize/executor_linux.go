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

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"github.com/booxter/nix-config/media-repair/worker/cuesheet"
	"github.com/booxter/nix-config/media-repair/worker/mediaevidence"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
	"golang.org/x/sys/unix"
)

const (
	workspaceDirectory = ".media-repair"
	workspaceManifest  = ".materialization.json"
	manifestVersion    = "media-repair-workspace/v3"
	maximumEntries     = 4096
	maximumFileBytes   = 8 << 30
	maximumTotalBytes  = 32 << 30
)

var audioExtensions = map[string]struct{}{
	".flac": {}, ".wav": {}, ".ape": {}, ".wv": {}, ".m4a": {},
	".mp3": {}, ".ogg": {}, ".opus": {},
}

var videoExtensions = map[string]struct{}{
	".ts": {}, ".m2ts": {}, ".mp4": {}, ".mkv": {}, ".avi": {},
}

var (
	errNoSupportedAudio   = errors.New("source contains no supported audio")
	errDirectoryRead      = errors.New("read source directory")
	errDirectoryEntry     = errors.New("invalid source directory entry")
	errDirectorySymlink   = errors.New("source directory contains a symbolic link")
	errDirectorySpecial   = errors.New("source directory contains a special file")
	errDirectoryLimit     = errors.New("source directory exceeds limits")
	errDirectoryEntryInfo = errors.New("read source directory entry metadata")
	errDirectoryCopy      = errors.New("copy directory audio")
	errDirectoryProbe     = errors.New("probe directory audio")
	errDirectoryChanged   = errors.New("source directory changed")
	errDirectoryCue       = errors.New("invalid cue-backed audio image")
)

type Files interface {
	Open(string, []string, string) (*os.File, error)
	OpenDirectory(string, []string) (*os.File, error)
	Path(string) (string, error)
	Verify(*os.File, string) error
}

type Prober interface {
	Probe(context.Context, string) (controller.ProbeEvidence, error)
}

type RARExtractor interface {
	Extract(context.Context, *os.File, string) error
}

type CueHandler interface {
	Inspect(context.Context, *os.File) (cuesheet.Plan, error)
	Split(context.Context, *os.File, cuesheet.Plan, string) ([]string, error)
}

type Executor struct {
	files  Files
	prober Prober
	rar    RARExtractor
	cue    CueHandler
}

type manifest struct {
	Version           string  `json:"version"`
	SourceOperation   string  `json:"source_operation"`
	SourceFingerprint string  `json:"source_fingerprint"`
	Success           Success `json:"success"`
}

func NewExecutor(files Files, prober Prober, rar RARExtractor, cue CueHandler) (*Executor, error) {
	if files == nil || prober == nil {
		return nil, fmt.Errorf("materialization requires media access and probing")
	}
	return &Executor{files: files, prober: prober, rar: rar, cue: cue}, nil
}

func (executor *Executor) ExecuteRAR(ctx context.Context, request Request) Response {
	fail := func(reason string) Response {
		return Response{Status: "failed", Failure: &Failure{
			SchemaVersion: SchemaVersion, RequestID: request.RequestID,
			Operation: request.Operation, Reason: reason,
		}}
	}
	if executor.rar == nil {
		return fail("rar_unavailable")
	}
	extensions := audioExtensions
	mediaName := "audio"
	switch request.Operation {
	case OperationMaterializeRAR:
	case OperationMaterializeRARVideo:
		extensions = videoExtensions
		mediaName = "video"
	default:
		return fail("invalid_operation")
	}
	if err := ctx.Err(); err != nil {
		return fail("timeout")
	}
	archive, err := executor.files.Open(
		request.RootID, request.SourceComponents, request.ExpectedFingerprint,
	)
	if err != nil {
		return fail(reasonForError(err))
	}
	defer archive.Close()
	archiveInfo, err := archive.Stat()
	if err != nil {
		return fail(reasonForError(err))
	}
	archiveSnapshot, err := fileidentity.FromFileInfo(archiveInfo)
	if err != nil {
		return fail(reasonForError(err))
	}
	sourceFingerprint := archiveSnapshot.StableFingerprint()
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
	if success, found, loadErr := loadWorkspace(
		workspacePath, request, workspaceComponents, sourceFingerprint,
	); loadErr == nil && found {
		if err := executor.files.Verify(archive, request.ExpectedFingerprint); err != nil {
			return fail(reasonForError(err))
		}
		return Response{Status: "ok", Success: &success}
	} else if loadErr != nil {
		if clearErr := clearWorkspace(workspacePath); clearErr != nil {
			return fail("workspace_error")
		}
	}
	if err := prepareWorkspace(rootPath, partialPath, workspacePath, groupID); err != nil {
		return fail("workspace_error")
	}
	quarantine := filepath.Join(partialPath, ".rar-extract")
	if err := os.Mkdir(quarantine, 0o700); err != nil {
		_ = os.RemoveAll(partialPath)
		return fail("workspace_error")
	}
	if err := executor.rar.Extract(ctx, archive, quarantine); err != nil {
		_ = os.RemoveAll(partialPath)
		return fail(reasonForRARError(err))
	}
	artifacts, err := executor.collectExtractedMedia(
		ctx, quarantine, partialPath, workspaceComponents, groupID, extensions, mediaName,
	)
	if err != nil {
		_ = os.RemoveAll(partialPath)
		return fail(reasonForRARError(err))
	}
	if err := os.RemoveAll(quarantine); err != nil {
		_ = os.RemoveAll(partialPath)
		return fail("workspace_error")
	}
	if err := executor.files.Verify(archive, request.ExpectedFingerprint); err != nil {
		_ = os.RemoveAll(partialPath)
		return fail(reasonForError(err))
	}
	success := Success{
		SchemaVersion: SchemaVersion, RequestID: request.RequestID,
		Operation: request.Operation, RootID: request.RootID,
		SourceFingerprint: sourceFingerprint, WorkspaceComponents: workspaceComponents,
		Artifacts: artifacts,
	}
	if err := writeManifest(partialPath, request.Operation, sourceFingerprint, success); err != nil {
		_ = os.RemoveAll(partialPath)
		return fail("workspace_error")
	}
	if err := os.Rename(partialPath, workspacePath); err != nil {
		_ = os.RemoveAll(partialPath)
		return fail("workspace_error")
	}
	return Response{Status: "ok", Success: &success}
}

func (executor *Executor) Execute(ctx context.Context, request Request) Response {
	fail := func(reason string) Response {
		return Response{Status: "failed", Failure: &Failure{
			SchemaVersion: SchemaVersion, RequestID: request.RequestID,
			Operation: request.Operation, Reason: reason,
		}}
	}
	extensions := audioExtensions
	mediaName := "audio"
	switch request.Operation {
	case OperationMaterializeTar:
	case OperationMaterializeTarVideo:
		extensions = videoExtensions
		mediaName = "video"
	default:
		return fail("invalid_operation")
	}
	if err := ctx.Err(); err != nil {
		return fail("timeout")
	}
	archive, err := executor.files.Open(
		request.RootID, request.SourceComponents, request.ExpectedFingerprint,
	)
	if err != nil {
		return fail(reasonForError(err))
	}
	defer archive.Close()
	archiveInfo, err := archive.Stat()
	if err != nil {
		return fail(reasonForError(err))
	}
	archiveSnapshot, err := fileidentity.FromFileInfo(archiveInfo)
	if err != nil {
		return fail(reasonForError(err))
	}
	sourceFingerprint := archiveSnapshot.StableFingerprint()
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
	if success, found, err := loadWorkspace(
		workspacePath, request, workspaceComponents, sourceFingerprint,
	); err != nil {
		if clearErr := clearWorkspace(workspacePath); clearErr != nil {
			return fail("workspace_error")
		}
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
		ctx, archive, partialPath, workspaceComponents, groupID, extensions, mediaName,
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
		Operation: request.Operation, RootID: request.RootID,
		SourceFingerprint:   sourceFingerprint,
		WorkspaceComponents: workspaceComponents, Artifacts: artifacts,
	}
	if err := writeManifest(
		partialPath, request.Operation, sourceFingerprint, success,
	); err != nil {
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
	sourceFingerprint string,
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
	if stored.Version != manifestVersion || stored.SourceOperation != request.Operation ||
		stored.SourceFingerprint != sourceFingerprint ||
		stored.Success.Operation != request.Operation ||
		stored.Success.SourceFingerprint != sourceFingerprint ||
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

func writeManifest(
	workspacePath string,
	sourceOperation string,
	sourceFingerprint string,
	success Success,
) error {
	data, err := json.Marshal(manifest{
		Version: manifestVersion, SourceOperation: sourceOperation,
		SourceFingerprint: sourceFingerprint, Success: success,
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

type directorySource struct {
	files       []directoryFile
	cueFiles    []directoryFile
	cue         *cuePlan
	fingerprint string
	bytes       int64
}

type cuePlan struct {
	plan  cuesheet.Plan
	image directoryFile
	cue   directoryFile
}

type directoryFile struct {
	components []string
	relative   string
	snapshot   fileidentity.Snapshot
}

func (executor *Executor) ExecuteDirectory(ctx context.Context, request Request) Response {
	fail := func(reason string) Response {
		return Response{Status: "failed", Failure: &Failure{
			SchemaVersion: SchemaVersion, RequestID: request.RequestID,
			Operation: OperationMaterializeDirectory, Reason: reason,
		}}
	}
	if err := ctx.Err(); err != nil {
		return fail("timeout")
	}
	source, err := executor.scanDirectory(ctx, request.RootID, request.SourceComponents)
	if err != nil {
		return fail(reasonForDirectoryError(err))
	}
	rootPath, err := executor.files.Path(request.RootID)
	if err != nil {
		return fail(reasonForDirectoryError(err))
	}
	workspaceComponents := []string{workspaceDirectory, "workspaces", request.WorkspaceID}
	workspacePath := filepath.Join(append([]string{rootPath}, workspaceComponents...)...)
	partialPath := workspacePath + ".partial"
	groupID, err := workspaceGroup(rootPath)
	if err != nil {
		return fail("workspace_error")
	}
	if success, found, loadErr := loadWorkspace(
		workspacePath, request, workspaceComponents, source.fingerprint,
	); loadErr == nil && found {
		return Response{Status: "ok", Success: &success}
	} else if loadErr != nil {
		if clearErr := clearWorkspace(workspacePath); clearErr != nil {
			return fail("workspace_error")
		}
	}
	if err := prepareWorkspace(rootPath, partialPath, workspacePath, groupID); err != nil {
		return fail("workspace_error")
	}
	artifacts, err := executor.copyAndProbeDirectory(
		ctx, request, source, partialPath, workspaceComponents, groupID,
	)
	if err != nil {
		_ = os.RemoveAll(partialPath)
		return fail(reasonForDirectoryError(err))
	}
	current, err := executor.scanDirectory(ctx, request.RootID, request.SourceComponents)
	if err != nil || current.fingerprint != source.fingerprint {
		_ = os.RemoveAll(partialPath)
		if err == nil {
			err = errDirectoryChanged
		} else {
			err = fmt.Errorf("%w: %v", errDirectoryChanged, err)
		}
		return fail(reasonForDirectoryError(err))
	}
	success := Success{
		SchemaVersion: SchemaVersion, RequestID: request.RequestID,
		Operation: OperationMaterializeDirectory, RootID: request.RootID,
		SourceFingerprint:   source.fingerprint,
		WorkspaceComponents: workspaceComponents, Artifacts: artifacts,
	}
	if err := writeManifest(
		partialPath, request.Operation, source.fingerprint, success,
	); err != nil {
		_ = os.RemoveAll(partialPath)
		return fail("workspace_error")
	}
	if err := os.Rename(partialPath, workspacePath); err != nil {
		_ = os.RemoveAll(partialPath)
		return fail("workspace_error")
	}
	return Response{Status: "ok", Success: &success}
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

func (executor *Executor) scanDirectory(
	ctx context.Context,
	rootID string,
	sourceComponents []string,
) (directorySource, error) {
	result := directorySource{}
	entries := 0
	var visit func([]string, []string) error
	visit = func(absoluteComponents, relativeComponents []string) (visitErr error) {
		if err := ctx.Err(); err != nil {
			return err
		}
		directory, err := executor.files.OpenDirectory(rootID, absoluteComponents)
		if err != nil {
			return err
		}
		defer func() {
			if err := directory.Close(); err != nil {
				visitErr = errors.Join(visitErr, fmt.Errorf("%w: %v", errDirectoryRead, err))
			}
		}()
		children, err := directory.ReadDir(-1)
		if err != nil {
			return fmt.Errorf("%w: %v", errDirectoryRead, err)
		}
		sort.Slice(children, func(left, right int) bool {
			return children[left].Name() < children[right].Name()
		})
		for _, child := range children {
			entries++
			if entries > maximumEntries {
				return errDirectoryLimit
			}
			name := child.Name()
			if name == "" || name == "." || name == ".." ||
				strings.ContainsAny(name, "/\x00") || len(name) > 255 {
				return errDirectoryEntry
			}
			var stat unix.Stat_t
			if err := unix.Fstatat(
				int(directory.Fd()), name, &stat, unix.AT_SYMLINK_NOFOLLOW,
			); err != nil {
				return fmt.Errorf("%w: %v", errDirectoryEntryInfo, err)
			}
			absolute := appendCopy(absoluteComponents, name)
			relative := appendCopy(relativeComponents, name)
			fileType := stat.Mode & unix.S_IFMT
			if fileType == unix.S_IFDIR {
				if _, err := safeArchiveName(name, false); err != nil {
					return errDirectoryEntry
				}
				if len(relative) > 64 {
					return errDirectoryLimit
				}
				if err := visit(absolute, relative); err != nil {
					return err
				}
				continue
			}
			if fileType == unix.S_IFLNK {
				return errDirectorySymlink
			}
			if fileType != unix.S_IFREG {
				return errDirectorySpecial
			}
			_, audio := audioExtensions[strings.ToLower(filepath.Ext(name))]
			isCue := cueCandidate(name)
			if !audio && !isCue {
				continue
			}
			if _, err := safeArchiveName(name, false); err != nil {
				return errDirectoryEntry
			}
			maximumBytes := int64(maximumFileBytes)
			if isCue {
				maximumBytes = cuesheet.MaximumBytes
			}
			if stat.Size <= 0 || stat.Size > maximumBytes ||
				result.bytes > maximumTotalBytes-stat.Size {
				return errDirectoryLimit
			}
			snapshot := fileidentity.Snapshot{
				Device: uint64(stat.Dev), Inode: stat.Ino, SizeBytes: stat.Size,
				MTimeNS: stat.Mtim.Sec*1_000_000_000 + stat.Mtim.Nsec,
			}
			result.bytes += stat.Size
			observed := directoryFile{
				components: absolute,
				relative:   strings.Join(relative, "/"),
				snapshot:   snapshot,
			}
			if audio {
				result.files = append(result.files, observed)
			} else {
				result.cueFiles = append(result.cueFiles, observed)
			}
		}
		return nil
	}
	if err := visit(sourceComponents, nil); err != nil {
		return directorySource{}, err
	}
	if len(result.files) == 0 {
		return directorySource{}, errNoSupportedAudio
	}
	plan, err := executor.readCuePlan(ctx, rootID, result.files, result.cueFiles)
	if err != nil {
		return directorySource{}, err
	}
	result.cue = plan
	result.fingerprint = directoryFingerprint(
		append(append([]directoryFile(nil), result.files...), result.cueFiles...),
	)
	return result, nil
}

func cueCandidate(name string) bool {
	lower := strings.ToLower(name)
	return strings.HasSuffix(lower, ".cue") || strings.HasSuffix(lower, ".cue.txt")
}

func (executor *Executor) readCuePlan(
	ctx context.Context,
	rootID string,
	audioFiles []directoryFile,
	cueFiles []directoryFile,
) (*cuePlan, error) {
	if len(cueFiles) == 0 {
		return nil, nil
	}
	if executor.cue == nil {
		return nil, fmt.Errorf("%w: cue handling is unavailable", errDirectoryCue)
	}
	var selected *cuePlan
	for _, cueFile := range cueFiles {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		input, err := executor.files.Open(
			rootID, cueFile.components, cueFile.snapshot.StrictFingerprint(),
		)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", errDirectoryCue, err)
		}
		plan, inspectErr := executor.cue.Inspect(ctx, input)
		verifyErr := executor.files.Verify(input, cueFile.snapshot.StrictFingerprint())
		closeErr := input.Close()
		if inspectErr != nil {
			if verifyErr == nil && closeErr == nil &&
				strings.HasSuffix(strings.ToLower(cueFile.relative), ".cue.txt") {
				continue
			}
			return nil, fmt.Errorf(
				"%w: %v", errDirectoryCue, errors.Join(inspectErr, verifyErr, closeErr),
			)
		}
		if verifyErr != nil || closeErr != nil {
			return nil, fmt.Errorf(
				"%w: %v", errDirectoryCue, errors.Join(verifyErr, closeErr),
			)
		}
		if selected != nil || len(audioFiles) != 1 {
			return nil, fmt.Errorf("%w: ambiguous cue sources", errDirectoryCue)
		}
		selected = &cuePlan{plan: plan, image: audioFiles[0], cue: cueFile}
	}
	return selected, nil
}

func directoryFingerprint(files []directoryFile) string {
	hash := sha256.New()
	for _, file := range files {
		_, _ = io.WriteString(hash, file.relative)
		_, _ = hash.Write([]byte{0})
		_, _ = io.WriteString(hash, file.snapshot.StableFingerprint())
		_, _ = hash.Write([]byte{0})
	}
	return "sha256:" + hex.EncodeToString(hash.Sum(nil))
}

func (executor *Executor) copyAndProbeDirectory(
	ctx context.Context,
	request Request,
	source directorySource,
	workspacePath string,
	workspaceComponents []string,
	groupID int,
) ([]Artifact, error) {
	if source.cue != nil {
		return executor.splitAndProbeDirectory(
			ctx, request, *source.cue, workspacePath, workspaceComponents, groupID,
		)
	}
	artifacts := make([]Artifact, 0, len(source.files))
	for _, sourceFile := range source.files {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		input, err := executor.files.Open(
			request.RootID, sourceFile.components, sourceFile.snapshot.StrictFingerprint(),
		)
		if err != nil {
			return nil, err
		}
		artifact, copyErr := copyDirectoryFile(
			input, workspacePath, workspaceComponents, sourceFile, groupID,
		)
		verifyErr := executor.files.Verify(input, sourceFile.snapshot.StrictFingerprint())
		closeErr := input.Close()
		if copyErr != nil || verifyErr != nil || closeErr != nil {
			return nil, fmt.Errorf(
				"%w: %v", errDirectoryCopy, errors.Join(copyErr, verifyErr, closeErr),
			)
		}
		evidence, err := executor.prober.Probe(
			ctx, filepath.Join(workspacePath, filepath.FromSlash(sourceFile.relative)),
		)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", errDirectoryProbe, err)
		}
		artifact.Evidence = mediaevidence.FromProbe(evidence)
		artifacts = append(artifacts, artifact)
	}
	return artifacts, nil
}

func (executor *Executor) splitAndProbeDirectory(
	ctx context.Context,
	request Request,
	plan cuePlan,
	workspacePath string,
	workspaceComponents []string,
	groupID int,
) ([]Artifact, error) {
	image, err := executor.files.Open(
		request.RootID, plan.image.components, plan.image.snapshot.StrictFingerprint(),
	)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errDirectoryCopy, err)
	}
	defer image.Close()
	outputs, splitErr := executor.cue.Split(ctx, image, plan.plan, workspacePath)
	verifyErr := executor.files.Verify(image, plan.image.snapshot.StrictFingerprint())
	if splitErr != nil || verifyErr != nil {
		return nil, fmt.Errorf("%w: %v", errDirectoryCue, errors.Join(splitErr, verifyErr))
	}
	artifacts := make([]Artifact, 0, len(outputs))
	var total int64
	for _, name := range outputs {
		if _, err := safeArchiveName(name, false); err != nil || strings.Contains(name, "/") {
			return nil, fmt.Errorf("%w: unsafe split output", errDirectoryCue)
		}
		output := filepath.Join(workspacePath, name)
		info, err := os.Lstat(output)
		if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 ||
			info.Size() <= 0 || info.Size() > maximumFileBytes ||
			total > maximumTotalBytes-info.Size() {
			return nil, fmt.Errorf("%w: invalid split output", errDirectoryCue)
		}
		total += info.Size()
		if err := os.Chmod(output, 0o640); err != nil {
			return nil, fmt.Errorf("%w: %v", errDirectoryCopy, err)
		}
		if err := os.Chown(output, -1, groupID); err != nil {
			return nil, fmt.Errorf("%w: %v", errDirectoryCopy, err)
		}
		artifact, err := generatedArtifact(output, name, workspaceComponents, info.Size())
		if err != nil {
			return nil, fmt.Errorf("%w: %v", errDirectoryCopy, err)
		}
		evidence, err := executor.prober.Probe(ctx, output)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", errDirectoryProbe, err)
		}
		artifact.Evidence = mediaevidence.FromProbe(evidence)
		artifacts = append(artifacts, artifact)
	}
	if len(artifacts) != len(plan.plan.Starts) {
		return nil, fmt.Errorf("%w: split output count changed", errDirectoryCue)
	}
	return artifacts, nil
}

func generatedArtifact(
	filename string,
	relative string,
	workspaceComponents []string,
	size int64,
) (Artifact, error) {
	input, err := os.Open(filename)
	if err != nil {
		return Artifact{}, err
	}
	hash := sha256.New()
	written, copyErr := io.Copy(hash, input)
	closeErr := input.Close()
	if copyErr != nil || closeErr != nil || written != size {
		return Artifact{}, errors.Join(copyErr, closeErr, fmt.Errorf("short generated file"))
	}
	fingerprint := "sha256:" + hex.EncodeToString(hash.Sum(nil))
	return Artifact{
		ArtifactID:     ArtifactID(relative, fingerprint),
		PathComponents: appendCopy(workspaceComponents, relative),
		RelativePath:   relative, SizeBytes: size, Fingerprint: fingerprint,
	}, nil
}

func copyDirectoryFile(
	input *os.File,
	workspacePath string,
	workspaceComponents []string,
	source directoryFile,
	groupID int,
) (Artifact, error) {
	destination := filepath.Join(workspacePath, filepath.FromSlash(source.relative))
	if err := ensureWorkspaceDirectory(filepath.Dir(destination), groupID); err != nil {
		return Artifact{}, err
	}
	output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o640)
	if err != nil {
		return Artifact{}, err
	}
	hash := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(output, hash), input)
	closeErr := output.Close()
	if copyErr != nil || closeErr != nil || written != source.snapshot.SizeBytes {
		return Artifact{}, errors.Join(copyErr, closeErr, fmt.Errorf("short source file"))
	}
	if err := os.Chmod(destination, 0o640); err != nil {
		return Artifact{}, err
	}
	if err := os.Chown(destination, -1, groupID); err != nil {
		return Artifact{}, err
	}
	digest := hex.EncodeToString(hash.Sum(nil))
	fingerprint := "sha256:" + digest
	components := appendCopy(workspaceComponents, strings.Split(source.relative, "/")...)
	return Artifact{
		ArtifactID: ArtifactID(source.relative, fingerprint), PathComponents: components,
		RelativePath: source.relative, SizeBytes: written,
		Fingerprint: fingerprint,
	}, nil
}

func appendCopy(base []string, values ...string) []string {
	result := make([]string, 0, len(base)+len(values))
	result = append(result, base...)
	return append(result, values...)
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
	extensions map[string]struct{},
	mediaName string,
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
				extensions,
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
				return nil, fmt.Errorf("probe extracted %s: %w", mediaName, err)
			}
			artifact.Evidence = mediaevidence.FromProbe(evidence)
			artifacts = append(artifacts, artifact)
		default:
			return nil, fmt.Errorf("archive entry %q is not a regular file or directory", name)
		}
	}
	if len(artifacts) == 0 {
		return nil, fmt.Errorf("archive contains no supported %s", mediaName)
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
	extensions map[string]struct{},
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
	fingerprint := "sha256:" + digest
	components := append(append([]string(nil), workspaceComponents...), strings.Split(name, "/")...)
	_, audio := extensions[strings.ToLower(path.Ext(name))]
	return Artifact{
		ArtifactID: ArtifactID(name, fingerprint), PathComponents: components,
		RelativePath: name, SizeBytes: size, Fingerprint: fingerprint,
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

func reasonForDirectoryError(err error) string {
	switch {
	case errors.Is(err, errNoSupportedAudio):
		return FailureNoSupportedAudio
	case errors.Is(err, errDirectoryRead):
		return "directory_read_failed"
	case errors.Is(err, errDirectoryEntry):
		return "invalid_directory_entry"
	case errors.Is(err, errDirectorySymlink):
		return "directory_contains_symlink"
	case errors.Is(err, errDirectorySpecial):
		return "directory_contains_special_file"
	case errors.Is(err, errDirectoryLimit):
		return "directory_limit_exceeded"
	case errors.Is(err, errDirectoryEntryInfo):
		return "directory_entry_info_failed"
	case errors.Is(err, errDirectoryCopy):
		return "copy_failed"
	case errors.Is(err, errDirectoryProbe):
		return "probe_failed"
	case errors.Is(err, errDirectoryChanged):
		return "source_changed"
	case errors.Is(err, errDirectoryCue):
		return "invalid_cue_sheet"
	}
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
	return "invalid_directory"
}

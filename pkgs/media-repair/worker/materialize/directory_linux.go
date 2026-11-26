package materialize

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"github.com/booxter/nix-config/media-repair/worker/cuesheet"
	"github.com/booxter/nix-config/media-repair/worker/mediaevidence"
	"golang.org/x/sys/unix"
)

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
}

type directoryFile struct {
	components []string
	relative   string
	snapshot   fileidentity.Snapshot
}

func (executor *Executor) ExecuteDirectory(ctx context.Context, request Request) Response {
	if request.Operation != OperationMaterializeDirectory {
		return request.fail("invalid_operation")
	}
	if err := ctx.Err(); err != nil {
		return request.fail("timeout")
	}
	source, err := executor.scanDirectory(ctx, request.RootID, request.SourceComponents)
	if err != nil {
		return request.fail(reasonForDirectoryError(err))
	}
	rootPath, err := executor.files.Path(request.RootID)
	if err != nil {
		return request.fail(reasonForDirectoryError(err))
	}
	w, cached, err := openWorkspace(rootPath, request, source.fingerprint)
	if err != nil {
		return request.fail("workspace_error")
	}
	if cached != nil {
		return Response{Status: "ok", Success: cached}
	}
	artifacts, err := executor.copyAndProbeDirectory(
		ctx, request, source, w.partial, w.components, w.group,
	)
	if err != nil {
		_ = os.RemoveAll(w.partial)
		return request.fail(reasonForDirectoryError(err))
	}
	current, err := executor.scanDirectory(ctx, request.RootID, request.SourceComponents)
	if err != nil || current.fingerprint != source.fingerprint {
		_ = os.RemoveAll(w.partial)
		if err == nil {
			err = errDirectoryChanged
		} else {
			err = fmt.Errorf("%w: %v", errDirectoryChanged, err)
		}
		return request.fail(reasonForDirectoryError(err))
	}
	return w.publish(request, source.fingerprint, artifacts)
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
		return executor.readEmbeddedCuePlan(ctx, rootID, audioFiles)
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
		selected = &cuePlan{plan: plan, image: audioFiles[0]}
	}
	return selected, nil
}

func (executor *Executor) readEmbeddedCuePlan(
	ctx context.Context,
	rootID string,
	audioFiles []directoryFile,
) (*cuePlan, error) {
	if len(audioFiles) != 1 {
		return nil, nil
	}
	extension := strings.ToLower(filepath.Ext(audioFiles[0].relative))
	if extension != ".wv" && extension != ".wvp" {
		return nil, nil
	}
	if executor.cue == nil {
		return nil, fmt.Errorf("%w: cue handling is unavailable", errDirectoryCue)
	}
	image := audioFiles[0]
	input, err := executor.files.Open(rootID, image.components, image.snapshot.StrictFingerprint())
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errDirectoryCue, err)
	}
	plan, found, inspectErr := executor.cue.InspectEmbedded(ctx, input)
	verifyErr := executor.files.Verify(input, image.snapshot.StrictFingerprint())
	closeErr := input.Close()
	if inspectErr != nil || verifyErr != nil || closeErr != nil {
		return nil, fmt.Errorf(
			"%w: %v", errDirectoryCue, errors.Join(inspectErr, verifyErr, closeErr),
		)
	}
	if !found {
		return nil, nil
	}
	return &cuePlan{plan: plan, image: image}, nil
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
		return FailureInvalidCueSheet
	}
	return sourceFailureReason(err, "invalid_directory")
}

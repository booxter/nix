package materialize

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"github.com/booxter/nix-config/media-repair/worker/mediaevidence"
)

var (
	errRARListing   = errors.New("invalid RAR listing")
	errRARExtract   = errors.New("RAR extraction failed")
	errRARContent   = errors.New("invalid extracted RAR content")
	errRAREncrypted = errors.New("encrypted RAR archive")
)

const maximumRARListingBytes = 8 << 20

type ExternalRARExtractor struct {
	lsar string
	unar string
}

func NewRARExtractor(lsar, unar string) (*ExternalRARExtractor, error) {
	for name, executable := range map[string]string{"lsar": lsar, "unar": unar} {
		if executable == "" || !filepath.IsAbs(executable) || filepath.Clean(executable) != executable {
			return nil, fmt.Errorf("%s executable must be an absolute clean path", name)
		}
	}
	return &ExternalRARExtractor{lsar: lsar, unar: unar}, nil
}

type rarListing struct {
	FormatVersion int        `json:"lsarFormatVersion"`
	Contents      []rarEntry `json:"lsarContents"`
}

type rarEntry struct {
	FileName    string `json:"XADFileName"`
	FileSize    *int64 `json:"XADFileSize"`
	IsDirectory bool   `json:"XADIsDirectory"`
	IsLink      bool   `json:"XADIsLink"`
	IsEncrypted bool   `json:"XADIsEncrypted"`
}

func (extractor *ExternalRARExtractor) Extract(
	ctx context.Context,
	archive *os.File,
	destination string,
) error {
	if extractor == nil || archive == nil || destination == "" {
		return errRARExtract
	}
	listingData, err := runArchiveCommand(
		ctx, extractor.lsar, archive, maximumRARListingBytes, "-j", "-nr",
	)
	if err != nil {
		return fmt.Errorf("%w: %v", errRARListing, err)
	}
	if err := validateRARListing(listingData); err != nil {
		return err
	}
	if _, err := runArchiveCommand(
		ctx, extractor.unar, archive, 64<<10,
		"-q", "-D", "-s", "-nr", "-o", destination,
	); err != nil {
		return fmt.Errorf("%w: %v", errRARExtract, err)
	}
	return nil
}

func runArchiveCommand(
	ctx context.Context,
	executable string,
	archive *os.File,
	maximumOutput int64,
	arguments ...string,
) ([]byte, error) {
	if _, err := archive.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	arguments = append(arguments, "/proc/self/fd/3")
	command := exec.CommandContext(ctx, executable, arguments...)
	command.ExtraFiles = []*os.File{archive}
	var output bytes.Buffer
	stdout := &limitWriter{target: &output, remaining: maximumOutput}
	command.Stdout = stdout
	var stderr bytes.Buffer
	command.Stderr = &limitWriter{target: &stderr, remaining: 64<<10 - 1}
	if err := command.Run(); err != nil {
		return nil, fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	if stdout.exceeded {
		return nil, fmt.Errorf("command output exceeds limit")
	}
	return output.Bytes(), nil
}

type limitWriter struct {
	target    io.Writer
	remaining int64
	exceeded  bool
}

func (writer *limitWriter) Write(data []byte) (int, error) {
	if writer.target == nil {
		writer.target = io.Discard
	}
	if writer.remaining <= 0 {
		writer.exceeded = true
		return len(data), nil
	}
	writable := min(int64(len(data)), writer.remaining)
	_, _ = writer.target.Write(data[:writable])
	writer.remaining -= writable
	if writable != int64(len(data)) {
		writer.exceeded = true
	}
	return len(data), nil
}

func validateRARListing(data []byte) error {
	var listing rarListing
	// lsar intentionally exposes format-specific keys. Decode once into a loose
	// envelope, then strictly validate the fields that define extraction safety.
	var envelope struct {
		FormatVersion int               `json:"lsarFormatVersion"`
		Contents      []json.RawMessage `json:"lsarContents"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return fmt.Errorf("%w: %v", errRARListing, err)
	}
	listing.FormatVersion = envelope.FormatVersion
	listing.Contents = make([]rarEntry, len(envelope.Contents))
	for index, raw := range envelope.Contents {
		if err := json.Unmarshal(raw, &listing.Contents[index]); err != nil {
			return fmt.Errorf("%w: entry %d: %v", errRARListing, index, err)
		}
	}
	if listing.FormatVersion != 2 || len(listing.Contents) == 0 ||
		len(listing.Contents) > maximumEntries {
		return errRARListing
	}
	seen := make(map[string]struct{}, len(listing.Contents))
	var total int64
	for _, entry := range listing.Contents {
		name, err := safeArchiveName(entry.FileName, entry.IsDirectory)
		if err != nil {
			return fmt.Errorf("%w: %v", errRARListing, err)
		}
		if _, duplicate := seen[name]; duplicate {
			return fmt.Errorf("%w: duplicate path", errRARListing)
		}
		seen[name] = struct{}{}
		if entry.IsEncrypted {
			return errRAREncrypted
		}
		if entry.IsLink {
			return fmt.Errorf("%w: link entry", errRARListing)
		}
		if entry.IsDirectory {
			continue
		}
		if entry.FileSize == nil || *entry.FileSize < 0 || *entry.FileSize > maximumFileBytes ||
			total > maximumTotalBytes-*entry.FileSize {
			return fmt.Errorf("%w: expansion exceeds limits", errRARListing)
		}
		total += *entry.FileSize
	}
	return nil
}

func (executor *Executor) collectExtractedMedia(
	ctx context.Context,
	quarantine string,
	workspacePath string,
	workspaceComponents []string,
	groupID int,
	extensions map[string]struct{},
	mediaName string,
) ([]Artifact, error) {
	artifacts := make([]Artifact, 0)
	entries := 0
	var total int64
	err := filepath.WalkDir(quarantine, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if path == quarantine {
			return nil
		}
		entries++
		if entries > maximumEntries {
			return errRARContent
		}
		relative, err := filepath.Rel(quarantine, path)
		if err != nil {
			return errRARContent
		}
		name, err := safeArchiveName(filepath.ToSlash(relative), entry.IsDir())
		if err != nil {
			return fmt.Errorf("%w: %v", errRARContent, err)
		}
		info, err := entry.Info()
		if err != nil {
			return fmt.Errorf("%w: %v", errRARContent, err)
		}
		if info.Mode()&os.ModeSymlink != 0 || (!info.IsDir() && !info.Mode().IsRegular()) {
			return errRARContent
		}
		if info.IsDir() {
			return nil
		}
		if info.Size() < 0 || info.Size() > maximumFileBytes || total > maximumTotalBytes-info.Size() {
			return errRARContent
		}
		total += info.Size()
		if _, supported := extensions[strings.ToLower(filepath.Ext(name))]; !supported {
			return nil
		}
		artifact, err := copyExtractedFile(
			path, workspacePath, workspaceComponents, name, info.Size(), groupID,
		)
		if err != nil {
			return err
		}
		evidence, err := executor.prober.Probe(
			ctx, filepath.Join(workspacePath, filepath.FromSlash(name)),
		)
		if err != nil {
			return fmt.Errorf("probe extracted %s: %w", mediaName, err)
		}
		artifact.Evidence = mediaevidence.FromProbe(evidence)
		artifacts = append(artifacts, artifact)
		return nil
	})
	if err != nil {
		return nil, err
	}
	if len(artifacts) == 0 {
		return nil, fmt.Errorf("%w: no supported %s", errRARContent, mediaName)
	}
	sort.Slice(artifacts, func(left, right int) bool {
		return artifacts[left].RelativePath < artifacts[right].RelativePath
	})
	return artifacts, nil
}

func copyExtractedFile(
	sourcePath string,
	workspacePath string,
	workspaceComponents []string,
	name string,
	size int64,
	groupID int,
) (Artifact, error) {
	input, err := os.Open(sourcePath)
	if err != nil {
		return Artifact{}, err
	}
	defer input.Close()
	source := directoryFile{
		relative: name,
		snapshot: fileSnapshot(size),
	}
	return copyDirectoryFile(input, workspacePath, workspaceComponents, source, groupID)
}

func fileSnapshot(size int64) fileidentity.Snapshot {
	return fileidentity.Snapshot{SizeBytes: size}
}

func reasonForRARError(err error) string {
	switch {
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, errRAREncrypted):
		return FailureEncryptedArchive
	case errors.Is(err, errRARListing):
		return FailureInvalidArchive
	case errors.Is(err, errRARExtract):
		return "extract_failed"
	case errors.Is(err, errRARContent):
		return FailureInvalidArchive
	default:
		return FailureInvalidArchive
	}
}

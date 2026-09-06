package filesystem

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

type rootHandle interface {
	FS() fs.FS
	Lstat(string) (os.FileInfo, error)
	Open(string) (*os.File, error)
	Close() error
}

type rootOpener func(string) (rootHandle, error)

type Reader struct {
	openRoot rootOpener
}

var _ controller.FileInventoryReader = (*Reader)(nil)

func New() *Reader {
	return &Reader{
		openRoot: func(path string) (rootHandle, error) {
			return os.OpenRoot(path)
		},
	}
}

func (reader *Reader) Inventory(
	ctx context.Context,
	correlation controller.DownloadCorrelation,
) (controller.FileInventory, error) {
	if reader == nil || reader.openRoot == nil {
		return controller.FileInventory{}, fmt.Errorf("filesystem reader is not configured")
	}
	if !correlation.Eligible() {
		return controller.FileInventory{}, fmt.Errorf("download correlation is ineligible")
	}
	if err := ctx.Err(); err != nil {
		return controller.FileInventory{}, err
	}

	manifest, err := buildManifest(correlation)
	if err != nil {
		return controller.FileInventory{}, err
	}
	outerRootInfo, err := os.Lstat(correlation.DownloadRoot)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("inspect download root: %w", err)
	}
	if !outerRootInfo.IsDir() || outerRootInfo.Mode()&os.ModeSymlink != 0 {
		return controller.FileInventory{}, fmt.Errorf("download root is not a regular directory")
	}
	outerRootSnapshot, err := snapshot(outerRootInfo)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("inspect download root metadata: %w", err)
	}

	root, err := reader.openRoot(correlation.DownloadRoot)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("open download root: %w", err)
	}
	defer func() {
		_ = root.Close()
	}()
	openedRootInfo, err := root.Lstat(".")
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("inspect opened download root: %w", err)
	}
	if !openedRootInfo.IsDir() || openedRootInfo.Mode()&os.ModeSymlink != 0 {
		return controller.FileInventory{}, fmt.Errorf("opened download root is not a regular directory")
	}
	openedRootSnapshot, err := snapshot(openedRootInfo)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("inspect opened download root metadata: %w", err)
	}
	if !sameSnapshot(outerRootSnapshot, openedRootSnapshot) {
		return controller.FileInventory{}, fmt.Errorf("download root changed while it was opened")
	}

	observed := make([]observedFile, 0, len(manifest))
	snapshots := make([]entrySnapshot, 0, len(manifest)+1)
	err = fs.WalkDir(root.FS(), ".", func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if !fs.ValidPath(path) {
			return fmt.Errorf("filesystem returned invalid relative path %q", path)
		}
		info, err := entry.Info()
		if err != nil {
			return fmt.Errorf("inspect %q: %w", path, err)
		}
		entrySnapshot, err := newEntrySnapshot(path, info)
		if err != nil {
			return err
		}
		snapshots = append(snapshots, entrySnapshot)

		switch mode := info.Mode(); {
		case mode.IsDir():
			return nil
		case mode.IsRegular():
			openedInfo, err := openRegularFile(root, path, entrySnapshot)
			if err != nil {
				return err
			}
			observed = append(observed, observedFile{path: path, info: openedInfo})
			return nil
		case mode&os.ModeSymlink != 0:
			return fmt.Errorf("filesystem entry %q is a symbolic link", path)
		default:
			return fmt.Errorf("filesystem entry %q is not a regular file or directory", path)
		}
	})
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("walk download root: %w", err)
	}
	if err := recheckSnapshots(ctx, root, snapshots); err != nil {
		return controller.FileInventory{}, err
	}
	outerRootInfo, err = os.Lstat(correlation.DownloadRoot)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("recheck download root: %w", err)
	}
	if !outerRootInfo.IsDir() || outerRootInfo.Mode()&os.ModeSymlink != 0 {
		return controller.FileInventory{}, fmt.Errorf("download root changed type during inventory")
	}
	outerRootFinal, err := snapshot(outerRootInfo)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("recheck download root metadata: %w", err)
	}
	if !sameSnapshot(outerRootSnapshot, outerRootFinal) {
		return controller.FileInventory{}, fmt.Errorf("download root changed during inventory")
	}

	return assembleInventory(correlation, manifest, observed)
}

type manifestFile struct {
	file  controller.TransmissionFile
	found bool
}

func buildManifest(
	correlation controller.DownloadCorrelation,
) (map[string]*manifestFile, error) {
	manifest := make(map[string]*manifestFile, len(correlation.Transmission.Files))
	seenIndices := make(map[int]struct{}, len(correlation.Transmission.Files))
	for _, file := range correlation.Transmission.Files {
		if file.Index < 0 {
			return nil, fmt.Errorf("Transmission file index %d is invalid", file.Index)
		}
		if _, exists := seenIndices[file.Index]; exists {
			return nil, fmt.Errorf("Transmission file index %d is duplicated", file.Index)
		}
		seenIndices[file.Index] = struct{}{}

		relative, err := manifestRelativePath(correlation, file.Name)
		if err != nil {
			return nil, fmt.Errorf("Transmission file %d: %w", file.Index, err)
		}
		if _, exists := manifest[relative]; exists {
			return nil, fmt.Errorf("Transmission path %q is duplicated", relative)
		}
		manifest[relative] = &manifestFile{file: file}
	}
	return manifest, nil
}

func manifestRelativePath(
	correlation controller.DownloadCorrelation,
	name string,
) (string, error) {
	if name == "" || strings.ContainsRune(name, '\x00') || filepath.IsAbs(name) {
		return "", fmt.Errorf("path is invalid")
	}
	nativeName := filepath.FromSlash(name)
	if filepath.Clean(nativeName) != nativeName || nativeName == "." {
		return "", fmt.Errorf("path is not canonical")
	}
	absolute := filepath.Join(correlation.Transmission.DownloadDirectory, nativeName)
	relative, err := filepath.Rel(correlation.DownloadRoot, absolute)
	if err != nil || relative == "." || filepath.IsAbs(relative) ||
		relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path is outside the download root")
	}
	relative = filepath.ToSlash(relative)
	if !fs.ValidPath(relative) {
		return "", fmt.Errorf("relative path is invalid")
	}
	return relative, nil
}

type observedFile struct {
	path string
	info os.FileInfo
}

func openRegularFile(
	root rootHandle,
	path string,
	before entrySnapshot,
) (os.FileInfo, error) {
	// WalkDir never supplies trailing separators. Keeping that invariant also
	// avoids the final-symlink-with-trailing-slash os.Root vulnerability present
	// in Go 1.26.4.
	if path == "." || strings.HasSuffix(path, "/") {
		return nil, fmt.Errorf("regular file path %q is invalid", path)
	}
	file, err := root.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open regular file %q: %w", path, err)
	}
	info, statErr := file.Stat()
	closeErr := file.Close()
	if statErr != nil {
		return nil, fmt.Errorf("inspect opened file %q: %w", path, statErr)
	}
	if closeErr != nil {
		return nil, fmt.Errorf("close opened file %q: %w", path, closeErr)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("filesystem entry %q changed type while it was opened", path)
	}
	after, err := newEntrySnapshot(path, info)
	if err != nil {
		return nil, err
	}
	if !sameEntrySnapshot(before, after) {
		return nil, fmt.Errorf("filesystem entry %q changed while it was opened", path)
	}
	return info, nil
}

type entrySnapshot struct {
	path        string
	fingerprint controller.FileFingerprint
	mode        os.FileMode
}

func newEntrySnapshot(path string, info os.FileInfo) (entrySnapshot, error) {
	fingerprint, err := snapshot(info)
	if err != nil {
		return entrySnapshot{}, fmt.Errorf("inspect filesystem entry %q metadata: %w", path, err)
	}
	return entrySnapshot{
		path:        path,
		fingerprint: fingerprint,
		mode:        info.Mode(),
	}, nil
}

func snapshot(info os.FileInfo) (controller.FileFingerprint, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return controller.FileFingerprint{}, fmt.Errorf("unsupported filesystem metadata")
	}
	return controller.FileFingerprint{
		Device:    uint64(stat.Dev),
		Inode:     uint64(stat.Ino),
		SizeBytes: info.Size(),
		MTimeNS:   info.ModTime().UnixNano(),
	}, nil
}

func sameSnapshot(left, right controller.FileFingerprint) bool {
	return left == right
}

func sameEntrySnapshot(left, right entrySnapshot) bool {
	return left.mode == right.mode && sameSnapshot(left.fingerprint, right.fingerprint)
}

func recheckSnapshots(
	ctx context.Context,
	root rootHandle,
	snapshots []entrySnapshot,
) error {
	for _, before := range snapshots {
		if err := ctx.Err(); err != nil {
			return err
		}
		info, err := root.Lstat(before.path)
		if err != nil {
			return fmt.Errorf("recheck filesystem entry %q: %w", before.path, err)
		}
		after, err := newEntrySnapshot(before.path, info)
		if err != nil {
			return err
		}
		if !sameEntrySnapshot(before, after) {
			return fmt.Errorf("filesystem entry %q changed during inventory", before.path)
		}
	}
	return nil
}

func assembleInventory(
	correlation controller.DownloadCorrelation,
	manifest map[string]*manifestFile,
	observed []observedFile,
) (controller.FileInventory, error) {
	inventory := controller.FileInventory{
		Files: make([]controller.InventoryFile, 0, len(observed)),
		Paths: make([]controller.FilePathMapping, 0, len(observed)),
	}
	seenIDs := make(map[controller.FileID]struct{}, len(observed))
	for _, observedFile := range observed {
		fingerprint, err := snapshot(observedFile.info)
		if err != nil {
			return controller.FileInventory{}, fmt.Errorf(
				"inspect filesystem entry %q metadata: %w",
				observedFile.path,
				err,
			)
		}
		fileID := opaqueFileID(correlation.Transmission.Hash, observedFile.path)
		if _, exists := seenIDs[fileID]; exists {
			return controller.FileInventory{}, fmt.Errorf("opaque file ID collision")
		}
		seenIDs[fileID] = struct{}{}

		var reference *controller.TorrentFileReference
		if expected, exists := manifest[observedFile.path]; exists {
			if fingerprint.SizeBytes != expected.file.LengthBytes {
				return controller.FileInventory{}, fmt.Errorf(
					"filesystem entry %q size does not match Transmission",
					observedFile.path,
				)
			}
			expected.found = true
			reference = &controller.TorrentFileReference{
				Index:          expected.file.Index,
				LengthBytes:    expected.file.LengthBytes,
				BytesCompleted: expected.file.BytesCompleted,
				Wanted:         expected.file.Wanted,
			}
		}
		inventory.Files = append(inventory.Files, controller.InventoryFile{
			ID:             fileID,
			PathComponents: strings.Split(observedFile.path, "/"),
			Fingerprint:    fingerprint,
			TorrentFile:    reference,
		})
		inventory.Paths = append(inventory.Paths, controller.FilePathMapping{
			FileID:       fileID,
			AbsolutePath: filepath.Join(correlation.DownloadRoot, filepath.FromSlash(observedFile.path)),
		})
	}

	manifestPaths := make([]string, 0, len(manifest))
	for relative := range manifest {
		manifestPaths = append(manifestPaths, relative)
	}
	sort.Strings(manifestPaths)
	for _, relative := range manifestPaths {
		expected := manifest[relative]
		if expected.file.Wanted && !expected.found {
			return controller.FileInventory{}, fmt.Errorf(
				"wanted Transmission file %q is missing",
				relative,
			)
		}
	}
	return inventory, nil
}

func opaqueFileID(torrentHash, relativePath string) controller.FileID {
	digest := sha256.Sum256([]byte(
		"radarr-repair-file-v1\x00" + strings.ToLower(torrentHash) + "\x00" + relativePath,
	))
	return controller.FileID(fmt.Sprintf("file:%x", digest))
}

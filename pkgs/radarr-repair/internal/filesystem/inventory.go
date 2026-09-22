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

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/fileidentity"
	"github.com/booxter/nix-config/radarr-repair/internal/repairartifact"
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

type inventoryScope struct {
	rootPath   string
	walkPath   string
	singleFile bool
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

	scope, targetSnapshot, err := resolveInventoryScope(correlation.DownloadRoot)
	if err != nil {
		return controller.FileInventory{}, err
	}
	manifest, err := buildManifest(correlation, scope.rootPath)
	if err != nil {
		return controller.FileInventory{}, err
	}
	if err := validateManifestScope(
		manifest,
		scope,
		correlation.Download.ContentOwnership,
	); err != nil {
		return controller.FileInventory{}, err
	}

	outerRootInfo, err := os.Lstat(scope.rootPath)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("inspect inventory root: %w", err)
	}
	if !outerRootInfo.IsDir() || outerRootInfo.Mode()&os.ModeSymlink != 0 {
		return controller.FileInventory{}, fmt.Errorf("inventory root is not a regular directory")
	}
	outerRootSnapshot, err := snapshot(outerRootInfo)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("inspect inventory root metadata: %w", err)
	}

	root, err := reader.openRoot(scope.rootPath)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("open inventory root: %w", err)
	}
	defer func() {
		_ = root.Close()
	}()
	openedRootInfo, err := root.Lstat(".")
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("inspect opened inventory root: %w", err)
	}
	if !openedRootInfo.IsDir() || openedRootInfo.Mode()&os.ModeSymlink != 0 {
		return controller.FileInventory{}, fmt.Errorf("opened inventory root is not a regular directory")
	}
	openedRootSnapshot, err := snapshot(openedRootInfo)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("inspect opened inventory root metadata: %w", err)
	}
	if !sameSnapshot(outerRootSnapshot, openedRootSnapshot) {
		return controller.FileInventory{}, fmt.Errorf("inventory root changed while it was opened")
	}

	observed := make([]observedFile, 0, len(manifest))
	snapshots := make([]entrySnapshot, 0, len(manifest)+1)
	err = fs.WalkDir(root.FS(), scope.walkPath, func(path string, entry fs.DirEntry, walkErr error) error {
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
	outerRootInfo, err = os.Lstat(scope.rootPath)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("recheck inventory root: %w", err)
	}
	if !outerRootInfo.IsDir() || outerRootInfo.Mode()&os.ModeSymlink != 0 {
		return controller.FileInventory{}, fmt.Errorf("inventory root changed type during inventory")
	}
	outerRootFinal, err := snapshot(outerRootInfo)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("recheck inventory root metadata: %w", err)
	}
	if !sameSnapshot(outerRootSnapshot, outerRootFinal) {
		return controller.FileInventory{}, fmt.Errorf("inventory root changed during inventory")
	}
	targetInfo, err := os.Lstat(correlation.DownloadRoot)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("recheck download target: %w", err)
	}
	targetFinal, err := snapshot(targetInfo)
	if err != nil {
		return controller.FileInventory{}, fmt.Errorf("recheck download target metadata: %w", err)
	}
	if targetInfo.Mode()&os.ModeSymlink != 0 || !sameSnapshot(targetSnapshot, targetFinal) {
		return controller.FileInventory{}, fmt.Errorf("download target changed during inventory")
	}

	return assembleInventory(correlation, manifest, observed, scope.rootPath)
}

func resolveInventoryScope(downloadRoot string) (inventoryScope, controller.FileFingerprint, error) {
	info, err := os.Lstat(downloadRoot)
	if err != nil {
		return inventoryScope{}, controller.FileFingerprint{}, fmt.Errorf("inspect download target: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return inventoryScope{}, controller.FileFingerprint{}, fmt.Errorf(
			"download target is not a regular file or directory",
		)
	}
	targetSnapshot, err := snapshot(info)
	if err != nil {
		return inventoryScope{}, controller.FileFingerprint{}, fmt.Errorf(
			"inspect download target metadata: %w",
			err,
		)
	}
	switch {
	case info.IsDir():
		return inventoryScope{rootPath: downloadRoot, walkPath: "."}, targetSnapshot, nil
	case info.Mode().IsRegular():
		return inventoryScope{
			rootPath: filepath.Dir(downloadRoot), walkPath: filepath.Base(downloadRoot), singleFile: true,
		}, targetSnapshot, nil
	default:
		return inventoryScope{}, controller.FileFingerprint{}, fmt.Errorf(
			"download target is not a regular file or directory",
		)
	}
}

type manifestFile struct {
	file  controller.DownloadFile
	found bool
}

func buildManifest(
	correlation controller.DownloadCorrelation,
	inventoryRoot string,
) (map[string]*manifestFile, error) {
	switch correlation.Download.ContentOwnership {
	case controller.DownloadContentOutputTree:
		if len(correlation.Download.Files) != 0 {
			return nil, fmt.Errorf("output-tree download must not contain a source manifest")
		}
		return map[string]*manifestFile{}, nil
	case controller.DownloadContentManifest:
	default:
		return nil, fmt.Errorf(
			"download content ownership %q is invalid",
			correlation.Download.ContentOwnership,
		)
	}
	manifest := make(map[string]*manifestFile, len(correlation.Download.Files))
	seenIndices := make(map[int]struct{}, len(correlation.Download.Files))
	for _, file := range correlation.Download.Files {
		if file.Index < 0 {
			return nil, fmt.Errorf("download file index %d is invalid", file.Index)
		}
		if _, exists := seenIndices[file.Index]; exists {
			return nil, fmt.Errorf("download file index %d is duplicated", file.Index)
		}
		seenIndices[file.Index] = struct{}{}

		relative, err := manifestRelativePath(inventoryRoot, file.Path)
		if err != nil {
			return nil, fmt.Errorf("download file %d: %w", file.Index, err)
		}
		if _, exists := manifest[relative]; exists {
			return nil, fmt.Errorf("download path %q is duplicated", relative)
		}
		manifest[relative] = &manifestFile{file: file}
	}
	return manifest, nil
}

func validateManifestScope(
	manifest map[string]*manifestFile,
	scope inventoryScope,
	ownership controller.DownloadContentOwnership,
) error {
	if ownership == controller.DownloadContentOutputTree {
		return nil
	}
	if !scope.singleFile {
		return nil
	}
	if len(manifest) != 1 {
		return fmt.Errorf("single-file download has %d manifest files", len(manifest))
	}
	if _, exists := manifest[filepath.ToSlash(scope.walkPath)]; !exists {
		return fmt.Errorf("download manifest does not match single-file download")
	}
	return nil
}

func manifestRelativePath(inventoryRoot, name string) (string, error) {
	if name == "" || strings.ContainsRune(name, '\x00') || !filepath.IsAbs(name) {
		return "", fmt.Errorf("path is invalid")
	}
	if filepath.Clean(name) != name {
		return "", fmt.Errorf("path is not canonical")
	}
	relative, err := filepath.Rel(inventoryRoot, name)
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
	return fileidentity.FromFileInfo(info)
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
	inventoryRoot string,
) (controller.FileInventory, error) {
	inventory := controller.FileInventory{
		Files: make([]controller.InventoryFile, 0, len(observed)),
		Paths: make([]controller.FilePathMapping, 0, len(observed)),
	}
	seenIDs := make(map[controller.FileID]struct{}, len(observed))
	for _, observedFile := range observed {
		expected, inManifest := manifest[observedFile.path]
		// Published repair outputs are not source evidence. Excluding them when
		// they are absent from the download manifest keeps retries on one case ID.
		if !inManifest && repairartifact.IsPublishedName(filepath.Base(observedFile.path)) {
			continue
		}
		fingerprint, err := snapshot(observedFile.info)
		if err != nil {
			return controller.FileInventory{}, fmt.Errorf(
				"inspect filesystem entry %q metadata: %w",
				observedFile.path,
				err,
			)
		}
		fileID := opaqueFileID(correlation.Download.ID, observedFile.path)
		if _, exists := seenIDs[fileID]; exists {
			return controller.FileInventory{}, fmt.Errorf("opaque file ID collision")
		}
		seenIDs[fileID] = struct{}{}

		var reference *controller.DownloadFileReference
		if correlation.Download.ContentOwnership == controller.DownloadContentOutputTree {
			reference = &controller.DownloadFileReference{
				LengthBytes:    fingerprint.SizeBytes,
				BytesCompleted: fingerprint.SizeBytes,
				Selected:       true,
			}
		} else if inManifest {
			if fingerprint.SizeBytes != expected.file.LengthBytes {
				return controller.FileInventory{}, fmt.Errorf(
					"filesystem entry %q size does not match download manifest",
					observedFile.path,
				)
			}
			expected.found = true
			reference = &controller.DownloadFileReference{
				Index:          expected.file.Index,
				HasIndex:       expected.file.HasIndex,
				LengthBytes:    expected.file.LengthBytes,
				BytesCompleted: expected.file.BytesCompleted,
				Selected:       expected.file.Selected,
			}
		}
		inventory.Files = append(inventory.Files, controller.InventoryFile{
			ID:             fileID,
			PathComponents: strings.Split(observedFile.path, "/"),
			Fingerprint:    fingerprint,
			DownloadFile:   reference,
		})
		inventory.Paths = append(inventory.Paths, controller.FilePathMapping{
			FileID:       fileID,
			AbsolutePath: filepath.Join(inventoryRoot, filepath.FromSlash(observedFile.path)),
		})
	}

	manifestPaths := make([]string, 0, len(manifest))
	for relative := range manifest {
		manifestPaths = append(manifestPaths, relative)
	}
	sort.Strings(manifestPaths)
	for _, relative := range manifestPaths {
		expected := manifest[relative]
		if expected.file.Selected && !expected.found {
			return controller.FileInventory{}, fmt.Errorf(
				"selected download file %q is missing",
				relative,
			)
		}
	}
	return inventory, nil
}

func opaqueFileID(downloadID, relativePath string) controller.FileID {
	digest := sha256.Sum256([]byte(
		"radarr-repair-file-v1\x00" + downloadID + "\x00" + relativePath,
	))
	return controller.FileID(fmt.Sprintf("file:%x", digest))
}

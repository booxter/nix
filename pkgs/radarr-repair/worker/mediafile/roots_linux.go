package mediafile

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/internal/fileidentity"
	"golang.org/x/sys/unix"
)

type FailureKind uint8

const (
	FailureUnknownRoot FailureKind = iota + 1
	FailureInvalidPath
	FailureFileUnavailable
	FailureNotRegularFile
	FailureFingerprintMismatch
	FailureInsufficientSpace
	FailureArtifactExists
	FailureDestinationExists
	FailureInternal
)

type Failure struct {
	Kind  FailureKind
	cause error
}

func (failure *Failure) Error() string {
	switch failure.Kind {
	case FailureUnknownRoot:
		return "unknown media root"
	case FailureInvalidPath:
		return "invalid media path"
	case FailureFileUnavailable:
		return "media file is unavailable"
	case FailureNotRegularFile:
		return "media path is not a regular file"
	case FailureFingerprintMismatch:
		return "media file fingerprint changed"
	case FailureInsufficientSpace:
		return "insufficient space for staged media"
	case FailureArtifactExists:
		return "staged media artifact already exists"
	case FailureDestinationExists:
		return "published media destination already exists"
	default:
		return "media file access failed"
	}
}

func (failure *Failure) Unwrap() error {
	return failure.cause
}

type RootSet struct {
	roots map[string]*os.File
}

func NewRootSet(rootPaths map[string]string) (*RootSet, error) {
	rootIDs := make([]string, 0, len(rootPaths))
	for rootID := range rootPaths {
		rootIDs = append(rootIDs, rootID)
	}
	sort.Strings(rootIDs)

	rootSet := &RootSet{roots: make(map[string]*os.File, len(rootPaths))}
	for _, rootID := range rootIDs {
		rootPath := rootPaths[rootID]
		if rootID == "" {
			_ = rootSet.Close()
			return nil, fmt.Errorf("media root ID must not be empty")
		}
		if rootPath == "" || strings.ContainsRune(rootPath, '\x00') ||
			!filepath.IsAbs(rootPath) || filepath.Clean(rootPath) != rootPath {
			_ = rootSet.Close()
			return nil, fmt.Errorf("media root %q must have an absolute clean path", rootID)
		}

		fd, err := unix.Open(
			rootPath,
			unix.O_PATH|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW,
			0,
		)
		if err != nil {
			_ = rootSet.Close()
			return nil, fmt.Errorf("open media root %q: %w", rootID, err)
		}
		rootSet.roots[rootID] = os.NewFile(uintptr(fd), "media-root:"+rootID)
	}
	return rootSet, nil
}

func (rootSet *RootSet) Close() error {
	if rootSet == nil {
		return nil
	}
	var closeErrors []error
	for rootID, root := range rootSet.roots {
		if err := root.Close(); err != nil {
			closeErrors = append(closeErrors, fmt.Errorf("close media root %q: %w", rootID, err))
		}
	}
	rootSet.roots = nil
	return errors.Join(closeErrors...)
}

func (rootSet *RootSet) Open(
	rootID string,
	pathComponents []string,
	expectedFingerprint string,
) (*os.File, error) {
	if rootSet == nil || rootSet.roots == nil {
		return nil, &Failure{Kind: FailureInternal}
	}
	root, found := rootSet.roots[rootID]
	if !found {
		return nil, &Failure{Kind: FailureUnknownRoot}
	}
	if !validComponents(pathComponents) {
		return nil, &Failure{Kind: FailureInvalidPath}
	}

	// os.Root allows symlinks that remain beneath the root. openat2 is used
	// directly because worker paths must not contain symlinks at any depth.
	// O_NONBLOCK prevents a special file such as a FIFO from stalling before
	// fstat can reject it; it is cleared after confirming a regular file.
	fd, err := unix.Openat2(
		int(root.Fd()),
		strings.Join(pathComponents, "/"),
		&unix.OpenHow{
			Flags: uint64(
				unix.O_RDONLY | unix.O_CLOEXEC | unix.O_NOFOLLOW | unix.O_NONBLOCK,
			),
			Resolve: unix.RESOLVE_BENEATH |
				unix.RESOLVE_NO_SYMLINKS |
				unix.RESOLVE_NO_MAGICLINKS,
		},
	)
	if err != nil {
		return nil, classifyOpenFailure(err)
	}

	media := os.NewFile(uintptr(fd), "media")
	if err := rootSet.Verify(media, expectedFingerprint); err != nil {
		_ = media.Close()
		return nil, err
	}
	if err := unix.SetNonblock(fd, false); err != nil {
		_ = media.Close()
		return nil, &Failure{Kind: FailureInternal, cause: err}
	}
	return media, nil
}

// Verify compares current descriptor metadata with the expected fingerprint.
// Calling it both before and after ffprobe detects ordinary concurrent writes.
func (rootSet *RootSet) Verify(media *os.File, expectedFingerprint string) error {
	snapshot, err := snapshot(media)
	if err != nil {
		return err
	}
	if snapshot.Fingerprint() != expectedFingerprint {
		return &Failure{Kind: FailureFingerprintMismatch}
	}
	return nil
}

func snapshot(media *os.File) (fileidentity.Snapshot, error) {
	if media == nil {
		return fileidentity.Snapshot{}, &Failure{Kind: FailureInternal}
	}

	var stat unix.Stat_t
	if err := unix.Fstat(int(media.Fd()), &stat); err != nil {
		return fileidentity.Snapshot{}, &Failure{Kind: FailureFileUnavailable, cause: err}
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFREG {
		return fileidentity.Snapshot{}, &Failure{Kind: FailureNotRegularFile}
	}
	return fileidentity.Snapshot{
		Device:    uint64(stat.Dev),
		Inode:     stat.Ino,
		SizeBytes: stat.Size,
		MTimeNS:   stat.Mtim.Sec*1_000_000_000 + stat.Mtim.Nsec,
	}, nil
}

func validComponents(components []string) bool {
	if len(components) == 0 {
		return false
	}
	for _, component := range components {
		if component == "" || component == "." || component == ".." ||
			strings.ContainsAny(component, "/\x00") {
			return false
		}
	}
	return true
}

func classifyOpenFailure(err error) error {
	switch {
	case errors.Is(err, unix.ELOOP), errors.Is(err, unix.EXDEV),
		errors.Is(err, unix.ENAMETOOLONG):
		return &Failure{Kind: FailureInvalidPath, cause: err}
	case errors.Is(err, unix.ENOENT), errors.Is(err, unix.ENOTDIR),
		errors.Is(err, unix.EACCES), errors.Is(err, unix.EPERM),
		errors.Is(err, unix.EAGAIN):
		return &Failure{Kind: FailureFileUnavailable, cause: err}
	default:
		return &Failure{Kind: FailureInternal, cause: err}
	}
}

package mediafile

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"golang.org/x/sys/unix"
)

const (
	workerDirectoryName = ".radarr-repair"
	stagedDirectoryName = "staged"
	stagedNameDomain    = "radarr-repair-worker-staged-name-v1\x00"
)

type StagedArtifact interface {
	File() *os.File
	Snapshot() (string, int64, error)
	Retain() error
	Discard() error
}

type StagedArtifacts interface {
	CreateStaged(
		string,
		string,
		workercontracts.OutputContainer,
		int64,
	) (StagedArtifact, error)
}

type stagedArtifact struct {
	file      *os.File
	directory *os.File
	name      string
	closed    bool
}

var _ StagedArtifacts = (*RootSet)(nil)

func (rootSet *RootSet) CreateStaged(
	rootID string,
	artifactID string,
	container workercontracts.OutputContainer,
	requiredBytes int64,
) (StagedArtifact, error) {
	if rootSet == nil || rootSet.roots == nil {
		return nil, &Failure{Kind: FailureInternal}
	}
	root, found := rootSet.roots[rootID]
	if !found {
		return nil, &Failure{Kind: FailureUnknownRoot}
	}
	if artifactID == "" || requiredBytes <= 0 {
		return nil, &Failure{Kind: FailureInternal}
	}
	extension, err := stagedExtension(container)
	if err != nil {
		return nil, err
	}

	workerDirectory, err := ensurePrivateDirectory(root, workerDirectoryName)
	if err != nil {
		return nil, err
	}
	defer workerDirectory.Close()
	stagedDirectory, err := ensurePrivateDirectory(workerDirectory, stagedDirectoryName)
	if err != nil {
		return nil, err
	}
	if err := requireAvailableSpace(stagedDirectory, requiredBytes); err != nil {
		_ = stagedDirectory.Close()
		return nil, err
	}

	name := stagedName(artifactID, extension)
	fd, err := unix.Openat2(
		int(stagedDirectory.Fd()),
		name,
		&unix.OpenHow{
			Flags: uint64(
				unix.O_RDWR | unix.O_CREAT | unix.O_EXCL | unix.O_CLOEXEC | unix.O_NOFOLLOW,
			),
			Mode: unix.S_IRUSR | unix.S_IWUSR,
			Resolve: unix.RESOLVE_BENEATH |
				unix.RESOLVE_NO_SYMLINKS |
				unix.RESOLVE_NO_MAGICLINKS,
		},
	)
	if err != nil {
		_ = stagedDirectory.Close()
		if errors.Is(err, unix.EEXIST) {
			return nil, &Failure{Kind: FailureArtifactExists, cause: err}
		}
		return nil, &Failure{Kind: FailureInternal, cause: err}
	}
	file := os.NewFile(uintptr(fd), "staged-media")
	if err := unix.Fsync(int(stagedDirectory.Fd())); err != nil {
		_ = file.Close()
		_ = unix.Unlinkat(int(stagedDirectory.Fd()), name, 0)
		_ = stagedDirectory.Close()
		return nil, &Failure{Kind: FailureInternal, cause: err}
	}
	return &stagedArtifact{file: file, directory: stagedDirectory, name: name}, nil
}

func (artifact *stagedArtifact) File() *os.File {
	if artifact == nil || artifact.closed {
		return nil
	}
	return artifact.file
}

func (artifact *stagedArtifact) Snapshot() (string, int64, error) {
	if artifact == nil || artifact.closed {
		return "", 0, &Failure{Kind: FailureInternal}
	}
	current, err := snapshot(artifact.file)
	if err != nil {
		return "", 0, err
	}
	return current.Fingerprint(), current.SizeBytes, nil
}

func (artifact *stagedArtifact) Retain() error {
	if artifact == nil || artifact.closed {
		return &Failure{Kind: FailureInternal}
	}
	if err := unix.Fsync(int(artifact.directory.Fd())); err != nil {
		return &Failure{Kind: FailureInternal, cause: err}
	}
	artifact.closed = true
	_ = artifact.file.Close()
	_ = artifact.directory.Close()
	return nil
}

func (artifact *stagedArtifact) Discard() error {
	if artifact == nil || artifact.closed {
		return &Failure{Kind: FailureInternal}
	}
	artifact.closed = true
	closeErr := artifact.file.Close()
	unlinkErr := unix.Unlinkat(int(artifact.directory.Fd()), artifact.name, 0)
	if errors.Is(unlinkErr, unix.ENOENT) {
		unlinkErr = nil
	}
	return errors.Join(
		closeErr,
		unlinkErr,
		syncAndCloseDirectory(artifact.directory),
	)
}

func stagedExtension(container workercontracts.OutputContainer) (string, error) {
	switch container {
	case workercontracts.OutputContainerMKV:
		return ".mkv", nil
	case workercontracts.OutputContainerMP4:
		return ".mp4", nil
	default:
		return "", fmt.Errorf("unsupported staged media container %q", container)
	}
}

func stagedName(artifactID string, extension string) string {
	digest := sha256.New()
	_, _ = digest.Write([]byte(stagedNameDomain))
	_, _ = digest.Write([]byte(artifactID))
	return hex.EncodeToString(digest.Sum(nil)) + extension
}

func ensurePrivateDirectory(parent *os.File, name string) (*os.File, error) {
	if err := unix.Mkdirat(int(parent.Fd()), name, 0o700); err != nil &&
		!errors.Is(err, unix.EEXIST) {
		return nil, &Failure{Kind: FailureInternal, cause: err}
	}
	fd, err := unix.Openat2(
		int(parent.Fd()),
		name,
		&unix.OpenHow{
			Flags: unix.O_RDONLY | unix.O_DIRECTORY | unix.O_CLOEXEC | unix.O_NOFOLLOW,
			Resolve: unix.RESOLVE_BENEATH |
				unix.RESOLVE_NO_SYMLINKS |
				unix.RESOLVE_NO_MAGICLINKS,
		},
	)
	if err != nil {
		return nil, &Failure{Kind: FailureInternal, cause: err}
	}
	directory := os.NewFile(uintptr(fd), "private-media-directory")
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil ||
		stat.Mode&unix.S_IFMT != unix.S_IFDIR ||
		stat.Uid != uint32(os.Geteuid()) ||
		stat.Mode&0o077 != 0 {
		_ = directory.Close()
		return nil, &Failure{Kind: FailureInternal, cause: err}
	}
	return directory, nil
}

func requireAvailableSpace(directory *os.File, requiredBytes int64) error {
	var filesystem unix.Statfs_t
	if err := unix.Fstatfs(int(directory.Fd()), &filesystem); err != nil {
		return &Failure{Kind: FailureInternal, cause: err}
	}
	if filesystem.Bsize <= 0 || filesystem.Bavail < 0 {
		return &Failure{Kind: FailureInternal}
	}
	blockSize := uint64(filesystem.Bsize)
	requiredBlocks := uint64(requiredBytes) / blockSize
	if uint64(requiredBytes)%blockSize != 0 {
		requiredBlocks++
	}
	if uint64(filesystem.Bavail) < requiredBlocks {
		return &Failure{Kind: FailureInsufficientSpace}
	}
	return nil
}

func syncAndCloseDirectory(directory *os.File) error {
	if directory == nil {
		return &Failure{Kind: FailureInternal}
	}
	syncErr := unix.Fsync(int(directory.Fd()))
	closeErr := directory.Close()
	if err := errors.Join(syncErr, closeErr); err != nil {
		return &Failure{Kind: FailureInternal, cause: err}
	}
	return nil
}

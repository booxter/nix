package mediafile

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"golang.org/x/sys/unix"
)

const (
	workerDirectoryName = ".radarr-repair"
	stagedDirectoryName = "staged"
	stagedNameDomain    = "radarr-repair-worker-staged-name-v1\x00"
	publishedNameDomain = "radarr-repair-worker-published-name-v1\x00"
)

type StagedArtifact interface {
	File() *os.File
	Snapshot() (string, int64, error)
	Retain() error
	Discard() error
}

type CompletedArtifact interface {
	File() *os.File
	Snapshot() (string, int64, error)
	Close() error
}

type StagedStatus uint8

const (
	StagedMissing StagedStatus = iota
	StagedPartial
	StagedComplete
)

type StagedArtifacts interface {
	CreateStaged(
		string,
		string,
		workercontracts.OutputContainer,
		int64,
	) (StagedArtifact, error)
}

type RecoverableStagedArtifacts interface {
	StagedArtifacts
	InspectStaged(
		string,
		string,
		workercontracts.OutputContainer,
	) (StagedStatus, CompletedArtifact, error)
	RemovePartial(string, string, workercontracts.OutputContainer) (bool, error)
	RemoveCompleted(
		string,
		string,
		workercontracts.OutputContainer,
		string,
	) (bool, error)
}

type stagedArtifact struct {
	file          *os.File
	directory     *os.File
	name          string
	completedName string
	closed        bool
}

type completedArtifact struct {
	file   *os.File
	closed bool
}

var _ RecoverableStagedArtifacts = (*RootSet)(nil)

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

	completedName := stagedName(artifactID, extension)
	existing, found, err := openArtifact(stagedDirectory, completedName)
	if err != nil {
		_ = stagedDirectory.Close()
		return nil, err
	}
	if found {
		_ = existing.Close()
		_ = stagedDirectory.Close()
		return nil, &Failure{Kind: FailureArtifactExists}
	}
	name := partialStagedName(completedName)
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
	return &stagedArtifact{
		file:          file,
		directory:     stagedDirectory,
		name:          name,
		completedName: completedName,
	}, nil
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
	if err := artifact.file.Sync(); err != nil {
		return &Failure{Kind: FailureInternal, cause: err}
	}
	if err := unix.Renameat2(
		int(artifact.directory.Fd()),
		artifact.name,
		int(artifact.directory.Fd()),
		artifact.completedName,
		unix.RENAME_NOREPLACE,
	); err != nil {
		if errors.Is(err, unix.EEXIST) {
			return &Failure{Kind: FailureArtifactExists, cause: err}
		}
		return &Failure{Kind: FailureInternal, cause: err}
	}
	artifact.name = artifact.completedName
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

func (rootSet *RootSet) InspectStaged(
	rootID string,
	artifactID string,
	container workercontracts.OutputContainer,
) (StagedStatus, CompletedArtifact, error) {
	if rootSet == nil || rootSet.roots == nil {
		return StagedMissing, nil, &Failure{Kind: FailureInternal}
	}
	root, found := rootSet.roots[rootID]
	if !found {
		return StagedMissing, nil, &Failure{Kind: FailureUnknownRoot}
	}
	if artifactID == "" {
		return StagedMissing, nil, &Failure{Kind: FailureInternal}
	}
	extension, err := stagedExtension(container)
	if err != nil {
		return StagedMissing, nil, err
	}
	directory, found, err := openStagedDirectory(root)
	if err != nil || !found {
		return StagedMissing, nil, err
	}
	defer directory.Close()

	completedName := stagedName(artifactID, extension)
	completed, completeFound, err := openArtifact(directory, completedName)
	if err != nil {
		return StagedMissing, nil, err
	}
	partial, partialFound, err := openArtifact(directory, partialStagedName(completedName))
	if err != nil {
		if completeFound {
			_ = completed.Close()
		}
		return StagedMissing, nil, err
	}
	if partialFound {
		_ = partial.Close()
	}
	if completeFound && partialFound {
		_ = completed.Close()
		return StagedMissing, nil, &Failure{Kind: FailureArtifactExists}
	}
	if completeFound {
		return StagedComplete, &completedArtifact{file: completed}, nil
	}
	if partialFound {
		return StagedPartial, nil, nil
	}
	return StagedMissing, nil, nil
}

func (rootSet *RootSet) RemovePartial(
	rootID string,
	artifactID string,
	container workercontracts.OutputContainer,
) (bool, error) {
	status, completed, err := rootSet.InspectStaged(rootID, artifactID, container)
	if completed != nil {
		_ = completed.Close()
	}
	if err != nil {
		return false, err
	}
	if status != StagedPartial {
		return false, nil
	}
	extension, err := stagedExtension(container)
	if err != nil {
		return false, err
	}
	return rootSet.removeStagedName(
		rootID,
		partialStagedName(stagedName(artifactID, extension)),
		"",
	)
}

func (rootSet *RootSet) RemoveCompleted(
	rootID string,
	artifactID string,
	container workercontracts.OutputContainer,
	expectedFingerprint string,
) (bool, error) {
	if expectedFingerprint == "" {
		return false, &Failure{Kind: FailureInternal}
	}
	status, completed, err := rootSet.InspectStaged(rootID, artifactID, container)
	if completed != nil {
		_ = completed.Close()
	}
	if err != nil {
		return false, err
	}
	if status != StagedComplete {
		return false, nil
	}
	extension, err := stagedExtension(container)
	if err != nil {
		return false, err
	}
	return rootSet.removeStagedName(
		rootID,
		stagedName(artifactID, extension),
		expectedFingerprint,
	)
}

func (rootSet *RootSet) PublishCompleted(
	rootID string,
	artifactID string,
	container workercontracts.OutputContainer,
	expectedFingerprint string,
	inputPaths [][]string,
) ([]string, error) {
	if rootSet == nil || rootSet.roots == nil {
		return nil, &Failure{Kind: FailureInternal}
	}
	root, found := rootSet.roots[rootID]
	if !found {
		return nil, &Failure{Kind: FailureUnknownRoot}
	}
	if artifactID == "" || expectedFingerprint == "" {
		return nil, &Failure{Kind: FailureInternal}
	}
	extension, err := stagedExtension(container)
	if err != nil {
		return nil, err
	}
	directoryComponents, err := commonInputDirectory(inputPaths)
	if err != nil {
		return nil, err
	}
	name := publishedName(artifactID, extension)
	location := append(append([]string(nil), directoryComponents...), name)

	stagedDirectory, found, err := openStagedDirectory(root)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, &Failure{Kind: FailureFileUnavailable}
	}
	defer stagedDirectory.Close()
	destinationDirectory, err := openMediaDirectory(root, directoryComponents)
	if err != nil {
		return nil, err
	}
	defer destinationDirectory.Close()

	staged, stagedFound, err := openArtifact(
		stagedDirectory,
		stagedName(artifactID, extension),
	)
	if err != nil {
		return nil, err
	}
	if staged != nil {
		defer staged.Close()
	}
	published, publishedFound, err := openPublishedArtifact(destinationDirectory, name)
	if err != nil {
		return nil, err
	}
	if published != nil {
		defer published.Close()
	}

	var publishedArtifact *os.File
	if stagedFound {
		if err := verifyArtifactFingerprint(staged, expectedFingerprint); err != nil {
			return nil, err
		}
		if publishedFound {
			return nil, &Failure{Kind: FailureDestinationExists}
		}
		if err := unix.Renameat2(
			int(stagedDirectory.Fd()),
			stagedName(artifactID, extension),
			int(destinationDirectory.Fd()),
			name,
			unix.RENAME_NOREPLACE,
		); err != nil {
			switch {
			case errors.Is(err, unix.EEXIST):
				return nil, &Failure{Kind: FailureDestinationExists, cause: err}
			case errors.Is(err, unix.ENOENT):
				return nil, &Failure{Kind: FailureFileUnavailable, cause: err}
			default:
				return nil, &Failure{Kind: FailureInternal, cause: err}
			}
		}
		publishedArtifact = staged
	} else {
		if !publishedFound {
			return nil, &Failure{Kind: FailureFileUnavailable}
		}
		if err := verifyArtifactFingerprint(published, expectedFingerprint); err != nil {
			return nil, err
		}
		publishedArtifact = published
	}
	if err := makePublishedArtifactReadable(
		destinationDirectory,
		publishedArtifact,
	); err != nil {
		return nil, err
	}

	if err := errors.Join(
		syncDirectory(destinationDirectory),
		syncDirectory(stagedDirectory),
	); err != nil {
		return nil, err
	}
	return location, nil
}

func (artifact *completedArtifact) File() *os.File {
	if artifact == nil || artifact.closed {
		return nil
	}
	return artifact.file
}

func (artifact *completedArtifact) Snapshot() (string, int64, error) {
	if artifact == nil || artifact.closed {
		return "", 0, &Failure{Kind: FailureInternal}
	}
	current, err := snapshot(artifact.file)
	if err != nil {
		return "", 0, err
	}
	return current.Fingerprint(), current.SizeBytes, nil
}

func (artifact *completedArtifact) Close() error {
	if artifact == nil || artifact.closed {
		return &Failure{Kind: FailureInternal}
	}
	artifact.closed = true
	if err := artifact.file.Close(); err != nil {
		return &Failure{Kind: FailureInternal, cause: err}
	}
	return nil
}

func (rootSet *RootSet) removeStagedName(
	rootID string,
	name string,
	expectedFingerprint string,
) (bool, error) {
	if rootSet == nil || rootSet.roots == nil {
		return false, &Failure{Kind: FailureInternal}
	}
	root, found := rootSet.roots[rootID]
	if !found {
		return false, &Failure{Kind: FailureUnknownRoot}
	}
	directory, found, err := openStagedDirectory(root)
	if err != nil || !found {
		return false, err
	}
	defer directory.Close()
	artifact, found, err := openArtifact(directory, name)
	if err != nil || !found {
		return false, err
	}
	if expectedFingerprint != "" {
		current, err := snapshot(artifact)
		if err != nil {
			_ = artifact.Close()
			return false, err
		}
		if current.Fingerprint() != expectedFingerprint {
			_ = artifact.Close()
			return false, &Failure{Kind: FailureFingerprintMismatch}
		}
	}
	if err := artifact.Close(); err != nil {
		return false, &Failure{Kind: FailureInternal, cause: err}
	}
	if err := unix.Unlinkat(int(directory.Fd()), name, 0); err != nil {
		if errors.Is(err, unix.ENOENT) {
			return false, nil
		}
		return false, &Failure{Kind: FailureInternal, cause: err}
	}
	if err := unix.Fsync(int(directory.Fd())); err != nil {
		return false, &Failure{Kind: FailureInternal, cause: err}
	}
	return true, nil
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

func publishedName(artifactID string, extension string) string {
	digest := sha256.New()
	_, _ = digest.Write([]byte(publishedNameDomain))
	_, _ = digest.Write([]byte(artifactID))
	return "radarr-repair-" + hex.EncodeToString(digest.Sum(nil)) + extension
}

func commonInputDirectory(inputPaths [][]string) ([]string, error) {
	if len(inputPaths) < 2 {
		return nil, &Failure{Kind: FailureInvalidPath}
	}
	for _, path := range inputPaths {
		if !validComponents(path) {
			return nil, &Failure{Kind: FailureInvalidPath}
		}
	}
	common := append([]string(nil), inputPaths[0][:len(inputPaths[0])-1]...)
	for _, path := range inputPaths[1:] {
		parent := path[:len(path)-1]
		limit := min(len(common), len(parent))
		matched := 0
		for matched < limit && common[matched] == parent[matched] {
			matched++
		}
		common = common[:matched]
	}
	if len(common) > 0 && common[0] == workerDirectoryName {
		return nil, &Failure{Kind: FailureInvalidPath}
	}
	return common, nil
}

func openMediaDirectory(root *os.File, components []string) (*os.File, error) {
	path := "."
	if len(components) > 0 {
		path = strings.Join(components, "/")
	}
	fd, err := unix.Openat2(
		int(root.Fd()),
		path,
		&unix.OpenHow{
			Flags: unix.O_RDONLY | unix.O_DIRECTORY | unix.O_CLOEXEC | unix.O_NOFOLLOW,
			Resolve: unix.RESOLVE_BENEATH |
				unix.RESOLVE_NO_SYMLINKS |
				unix.RESOLVE_NO_MAGICLINKS,
		},
	)
	if err != nil {
		return nil, classifyOpenFailure(err)
	}
	return os.NewFile(uintptr(fd), "media-directory"), nil
}

func openPublishedArtifact(
	directory *os.File,
	name string,
) (*os.File, bool, error) {
	var directoryStat unix.Stat_t
	if err := unix.Fstat(int(directory.Fd()), &directoryStat); err != nil {
		return nil, false, &Failure{Kind: FailureInternal, cause: err}
	}
	fd, err := unix.Openat2(
		int(directory.Fd()),
		name,
		&unix.OpenHow{
			Flags: unix.O_RDONLY | unix.O_CLOEXEC | unix.O_NOFOLLOW | unix.O_NONBLOCK,
			Resolve: unix.RESOLVE_BENEATH |
				unix.RESOLVE_NO_SYMLINKS |
				unix.RESOLVE_NO_MAGICLINKS,
		},
	)
	if err != nil {
		if errors.Is(err, unix.ENOENT) {
			return nil, false, nil
		}
		return nil, true, &Failure{Kind: FailureDestinationExists, cause: err}
	}
	artifact := os.NewFile(uintptr(fd), "published-media")
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil {
		_ = artifact.Close()
		return nil, true, &Failure{Kind: FailureDestinationExists, cause: err}
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFREG ||
		stat.Uid != uint32(os.Geteuid()) ||
		(stat.Mode&0o777 != 0o600 &&
			(stat.Mode&0o777 != 0o640 || stat.Gid != directoryStat.Gid)) {
		_ = artifact.Close()
		return nil, true, &Failure{Kind: FailureDestinationExists}
	}
	return artifact, true, nil
}

func makePublishedArtifactReadable(directory *os.File, artifact *os.File) error {
	var stat unix.Stat_t
	if err := unix.Fstat(int(directory.Fd()), &stat); err != nil {
		return &Failure{Kind: FailureInternal, cause: err}
	}
	if err := unix.Fchown(int(artifact.Fd()), -1, int(stat.Gid)); err != nil {
		return &Failure{Kind: FailureInternal, cause: err}
	}
	if err := unix.Fchmod(int(artifact.Fd()), 0o640); err != nil {
		return &Failure{Kind: FailureInternal, cause: err}
	}
	if err := unix.Fsync(int(artifact.Fd())); err != nil {
		return &Failure{Kind: FailureInternal, cause: err}
	}
	return nil
}

func verifyArtifactFingerprint(artifact *os.File, expected string) error {
	current, err := snapshot(artifact)
	if err != nil {
		return err
	}
	if current.Fingerprint() != expected {
		return &Failure{Kind: FailureFingerprintMismatch}
	}
	return nil
}

func partialStagedName(completedName string) string {
	return completedName + ".partial"
}

func openStagedDirectory(root *os.File) (*os.File, bool, error) {
	workerDirectory, found, err := openPrivateDirectory(root, workerDirectoryName)
	if err != nil || !found {
		return nil, false, err
	}
	defer workerDirectory.Close()
	directory, found, err := openPrivateDirectory(workerDirectory, stagedDirectoryName)
	if err != nil || !found {
		return nil, false, err
	}
	return directory, true, nil
}

func openPrivateDirectory(parent *os.File, name string) (*os.File, bool, error) {
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
	if errors.Is(err, unix.ENOENT) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, &Failure{Kind: FailureInternal, cause: err}
	}
	directory := os.NewFile(uintptr(fd), "private-media-directory")
	if err := validatePrivateDirectory(directory); err != nil {
		_ = directory.Close()
		return nil, false, err
	}
	return directory, true, nil
}

func openArtifact(directory *os.File, name string) (*os.File, bool, error) {
	fd, err := unix.Openat2(
		int(directory.Fd()),
		name,
		&unix.OpenHow{
			Flags: unix.O_RDONLY | unix.O_CLOEXEC | unix.O_NOFOLLOW | unix.O_NONBLOCK,
			Resolve: unix.RESOLVE_BENEATH |
				unix.RESOLVE_NO_SYMLINKS |
				unix.RESOLVE_NO_MAGICLINKS,
		},
	)
	if errors.Is(err, unix.ENOENT) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, &Failure{Kind: FailureInternal, cause: err}
	}
	file := os.NewFile(uintptr(fd), "staged-media")
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil ||
		stat.Mode&unix.S_IFMT != unix.S_IFREG ||
		stat.Uid != uint32(os.Geteuid()) ||
		stat.Mode&0o777 != 0o600 {
		_ = file.Close()
		return nil, false, &Failure{Kind: FailureInternal, cause: err}
	}
	return file, true, nil
}

func ensurePrivateDirectory(parent *os.File, name string) (*os.File, error) {
	created := false
	if err := unix.Mkdirat(int(parent.Fd()), name, 0o700); err != nil {
		if !errors.Is(err, unix.EEXIST) {
			return nil, &Failure{Kind: FailureInternal, cause: err}
		}
	} else {
		created = true
	}
	directory, found, err := openPrivateDirectory(parent, name)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, &Failure{Kind: FailureInternal}
	}
	if created {
		if err := syncDirectory(parent); err != nil {
			_ = directory.Close()
			return nil, err
		}
	}
	return directory, nil
}

func validatePrivateDirectory(directory *os.File) error {
	var stat unix.Stat_t
	if err := unix.Fstat(int(directory.Fd()), &stat); err != nil ||
		stat.Mode&unix.S_IFMT != unix.S_IFDIR ||
		stat.Uid != uint32(os.Geteuid()) ||
		stat.Mode&0o077 != 0 {
		return &Failure{Kind: FailureInternal, cause: err}
	}
	return nil
}

func syncDirectory(directory *os.File) error {
	fd, err := unix.Openat(
		int(directory.Fd()),
		".",
		unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW,
		0,
	)
	if err != nil {
		return &Failure{Kind: FailureInternal, cause: err}
	}
	defer unix.Close(fd)
	if err := unix.Fsync(fd); err != nil {
		return &Failure{Kind: FailureInternal, cause: err}
	}
	return nil
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

package casestore

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"golang.org/x/sys/unix"
)

const (
	casesDirectoryName    = "cases"
	planningDirectoryName = "planning"
	lockFileName          = ".lock"
)

type Store struct {
	root        string
	casesDir    string
	planningDir string
}

func (store *Store) PutAssembly(assembly casebuilder.Assembly) (bool, error) {
	record, err := NewRecord(assembly)
	if err != nil {
		return false, err
	}
	return store.Put(record)
}

func New(root string) (*Store, error) {
	if root == "" || !filepath.IsAbs(root) || filepath.Clean(root) != root || filepath.Dir(root) == root {
		return nil, fmt.Errorf("case store root must be a clean absolute path")
	}
	if err := ensurePrivateDirectory(root); err != nil {
		return nil, fmt.Errorf("prepare case store root: %w", err)
	}
	casesDir := filepath.Join(root, casesDirectoryName)
	if err := ensurePrivateDirectory(casesDir); err != nil {
		return nil, fmt.Errorf("prepare case records directory: %w", err)
	}
	planningDir := filepath.Join(root, planningDirectoryName)
	if err := ensurePrivateDirectory(planningDir); err != nil {
		return nil, fmt.Errorf("prepare planning records directory: %w", err)
	}
	if err := syncDirectory(root); err != nil {
		return nil, fmt.Errorf("sync case store root: %w", err)
	}
	return &Store{root: root, casesDir: casesDir, planningDir: planningDir}, nil
}

// Put stores a record without replacing anything already published under its
// case ID. It reports false when the same case was stored by an earlier
// observation; any other difference is treated as a collision.
func (store *Store) Put(record CaseRecord) (bool, error) {
	data, err := EncodeRecord(record)
	if err != nil {
		return false, err
	}
	path, err := store.recordPath(record.CaseID)
	if err != nil {
		return false, err
	}

	lock, err := store.lock()
	if err != nil {
		return false, err
	}
	defer unlock(lock)

	found, err := store.compareExisting(path, record)
	if err != nil {
		return false, err
	}
	if found {
		if err := syncDirectory(store.casesDir); err != nil {
			return false, fmt.Errorf("sync case records directory: %w", err)
		}
		return false, nil
	}

	temporary, err := os.CreateTemp(store.casesDir, ".case-*.tmp")
	if err != nil {
		return false, fmt.Errorf("create temporary case record: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)

	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return false, fmt.Errorf("set temporary case record permissions: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return false, fmt.Errorf("write temporary case record: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return false, fmt.Errorf("sync temporary case record: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return false, fmt.Errorf("close temporary case record: %w", err)
	}

	if err := os.Link(temporaryPath, path); err != nil {
		if !errors.Is(err, os.ErrExist) {
			return false, fmt.Errorf("publish case record: %w", err)
		}
		found, compareErr := store.compareExisting(path, record)
		if compareErr != nil {
			return false, compareErr
		}
		if !found {
			return false, fmt.Errorf("case record disappeared during publication")
		}
		if err := syncDirectory(store.casesDir); err != nil {
			return false, fmt.Errorf("sync case records directory: %w", err)
		}
		return false, nil
	}
	if err := os.Remove(temporaryPath); err != nil {
		return false, fmt.Errorf("remove temporary case record: %w", err)
	}
	if err := syncDirectory(store.casesDir); err != nil {
		return false, fmt.Errorf("sync case records directory: %w", err)
	}
	return true, nil
}

func (store *Store) Get(caseID string) (CaseRecord, bool, error) {
	path, err := store.recordPath(caseID)
	if err != nil {
		return CaseRecord{}, false, err
	}
	record, found, err := readRecord(path)
	if err != nil {
		return CaseRecord{}, false, err
	}
	if !found {
		return CaseRecord{}, false, nil
	}
	if record.CaseID != caseID {
		return CaseRecord{}, false, fmt.Errorf("stored record has unexpected case ID %q", record.CaseID)
	}
	return record, true, nil
}

func (store *Store) compareExisting(path string, wanted CaseRecord) (bool, error) {
	existing, found, err := readRecord(path)
	if err != nil || !found {
		return found, err
	}
	equivalent, err := equivalentRecords(existing, wanted)
	if err != nil {
		return true, err
	}
	if !equivalent {
		return true, fmt.Errorf("case ID %q is already bound to different local state", wanted.CaseID)
	}
	return true, nil
}

func (store *Store) recordPath(caseID string) (string, error) {
	digest, err := caseDigest(caseID)
	if err != nil {
		return "", err
	}
	return filepath.Join(store.casesDir, digest+".json"), nil
}

func (store *Store) lock() (*os.File, error) {
	path := filepath.Join(store.root, lockFileName)
	fd, err := unix.Open(
		path,
		unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW,
		0o600,
	)
	if err != nil {
		return nil, fmt.Errorf("open case store lock: %w", err)
	}
	lock := os.NewFile(uintptr(fd), path)
	if err := lock.Chmod(0o600); err != nil {
		lock.Close()
		return nil, fmt.Errorf("set case store lock permissions: %w", err)
	}
	if err := unix.Flock(fd, unix.LOCK_EX); err != nil {
		lock.Close()
		return nil, fmt.Errorf("lock case store: %w", err)
	}
	return lock, nil
}

func unlock(lock *os.File) {
	_ = unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	_ = lock.Close()
}

func readRecord(path string) (CaseRecord, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return CaseRecord{}, false, nil
	}
	if err != nil {
		return CaseRecord{}, false, fmt.Errorf("read case record: %w", err)
	}
	record, err := DecodeRecord(data)
	if err != nil {
		return CaseRecord{}, true, fmt.Errorf("validate stored case record: %w", err)
	}
	return record, true, nil
}

func equivalentRecords(left, right CaseRecord) (bool, error) {
	leftRequest, err := contracts.DecodeCase(left.Request)
	if err != nil {
		return false, fmt.Errorf("decode existing repair case: %w", err)
	}
	rightRequest, err := contracts.DecodeCase(right.Request)
	if err != nil {
		return false, fmt.Errorf("decode new repair case: %w", err)
	}
	leftRequest.ObservedAt = rightRequest.ObservedAt

	leftSnapshot := left.Snapshot
	rightSnapshot := right.Snapshot
	leftSnapshot.Observation.ObservedAt = rightSnapshot.Observation.ObservedAt

	return left.Version == right.Version &&
		left.CaseID == right.CaseID &&
		reflect.DeepEqual(leftRequest, rightRequest) &&
		reflect.DeepEqual(leftSnapshot, rightSnapshot), nil
}

func caseDigest(caseID string) (string, error) {
	const prefix = "sha256:"
	if !strings.HasPrefix(caseID, prefix) || len(caseID) != len(prefix)+64 {
		return "", fmt.Errorf("invalid case ID %q", caseID)
	}
	digest := strings.TrimPrefix(caseID, prefix)
	for _, character := range digest {
		if (character < '0' || character > '9') && (character < 'a' || character > 'f') {
			return "", fmt.Errorf("invalid case ID %q", caseID)
		}
	}
	return digest, nil
}

func ensurePrivateDirectory(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("%q is not a directory", path)
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return err
	}
	return nil
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

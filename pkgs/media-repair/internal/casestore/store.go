package casestore

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/planningstate"
	"github.com/booxter/nix-config/media-repair/internal/privatefile"
	"golang.org/x/sys/unix"
)

const (
	casesDirectoryName     = "cases"
	planningDirectoryName  = "planning"
	executionDirectoryName = "executions"
	lockFileName           = ".lock"
)

type Store struct {
	root         string
	casesDir     string
	planningDir  string
	executionDir string
	cases        *planningstate.CaseStore[CaseRecord]
	results      *planningstate.ResultStore
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
	executionDir := filepath.Join(root, executionDirectoryName)
	if err := ensurePrivateDirectory(executionDir); err != nil {
		return nil, fmt.Errorf("prepare execution records directory: %w", err)
	}
	if err := syncDirectory(root); err != nil {
		return nil, fmt.Errorf("sync case store root: %w", err)
	}
	store := &Store{
		root: root, casesDir: casesDir, planningDir: planningDir,
		executionDir: executionDir,
	}
	lock := func() (func(), error) {
		stateLock, lockErr := store.lock()
		if lockErr != nil {
			return nil, lockErr
		}
		return func() { unlock(stateLock) }, nil
	}
	cases, err := planningstate.NewCaseStore(
		casesDir,
		lock,
		planningstate.CaseCodec[CaseRecord]{
			CaseID:       func(record CaseRecord) string { return record.CaseID },
			Encode:       EncodeRecord,
			Decode:       DecodeRecord,
			SameIdentity: sameRadarrCaseIdentity,
			Merge: func(_ CaseRecord, current CaseRecord) (CaseRecord, error) {
				return current, nil
			},
		},
	)
	if err != nil {
		return nil, err
	}
	store.cases = cases
	results, err := planningstate.NewResultStore(
		planningDir,
		lock,
		func(caseID string) (bool, error) {
			_, found, getErr := store.cases.Get(caseID)
			return found, getErr
		},
		validateRadarrDecision,
	)
	if err != nil {
		return nil, err
	}
	store.results = results
	return store, nil
}

// Put stores the latest local observation for immutable planning evidence. It
// reports whether this is the first observation of the case identity.
func (store *Store) Put(record CaseRecord) (bool, error) {
	observed, err := store.cases.Observe(record, nil)
	return observed.Created, err
}

func (store *Store) Get(caseID string) (CaseRecord, bool, error) {
	return store.cases.Get(caseID)
}

func (store *Store) recordPath(caseID string) (string, error) {
	digest, err := caseDigest(caseID)
	if err != nil {
		return "", err
	}
	return filepath.Join(store.casesDir, digest+".json"), nil
}

func (store *Store) lock() (*os.File, error) {
	lock, err := store.openLock(lockFileName, "case store lock")
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		lock.Close()
		return nil, fmt.Errorf("lock case store: %w", err)
	}
	return lock, nil
}

func (store *Store) openLock(name, description string) (*os.File, error) {
	path := filepath.Join(store.root, name)
	fd, err := unix.Open(
		path,
		unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW,
		0o600,
	)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", description, err)
	}
	lock := os.NewFile(uintptr(fd), path)
	if err := lock.Chmod(0o600); err != nil {
		lock.Close()
		return nil, fmt.Errorf("set %s permissions: %w", description, err)
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

func sameRadarrCaseIdentity(left, right CaseRecord) (bool, error) {
	leftRequest, err := contracts.DecodeCase(left.Request)
	if err != nil {
		return false, fmt.Errorf("decode existing repair case: %w", err)
	}
	rightRequest, err := contracts.DecodeCase(right.Request)
	if err != nil {
		return false, fmt.Errorf("decode new repair case: %w", err)
	}
	if left.CaseID != right.CaseID {
		return false, nil
	}
	return contracts.SameCaseIdentity(leftRequest, rightRequest)
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
	return privatefile.EnsureDirectory(path)
}

func syncDirectory(path string) error {
	return privatefile.SyncDirectory(path)
}

func replacePrivateFile(directory, path string, data []byte) error {
	return privatefile.Replace(directory, path, data)
}

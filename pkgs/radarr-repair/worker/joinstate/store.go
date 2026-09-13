package joinstate

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/privatefile"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"golang.org/x/sys/unix"
)

const (
	executionsDirectoryName = "executions"
	lockFileName            = ".lock"
	executionPathDomain     = "radarr-repair-worker-execution-path-v1\x00"
	artifactIDPrefix        = "artifact:"
)

type Store struct {
	root          string
	executionsDir string
}

type ConflictError struct {
	ExecutionID string
}

func (failure *ConflictError) Error() string {
	return fmt.Sprintf(
		"execution %q is already bound to a different join specification",
		failure.ExecutionID,
	)
}

func New(root string) (*Store, error) {
	if root == "" || !filepath.IsAbs(root) || filepath.Clean(root) != root ||
		filepath.Dir(root) == root {
		return nil, fmt.Errorf("join state root must be a clean absolute path")
	}
	if err := privatefile.EnsureDirectory(root); err != nil {
		return nil, fmt.Errorf("prepare join state root: %w", err)
	}
	executionsDir := filepath.Join(root, executionsDirectoryName)
	if err := privatefile.EnsureDirectory(executionsDir); err != nil {
		return nil, fmt.Errorf("prepare join executions directory: %w", err)
	}
	if err := privatefile.SyncDirectory(root); err != nil {
		return nil, fmt.Errorf("sync join state root: %w", err)
	}
	return &Store{root: root, executionsDir: executionsDir}, nil
}

func (store *Store) Prepare(
	request workercontracts.StageJoinRequestV1,
	preparedAt time.Time,
) (Execution, bool, error) {
	if preparedAt.IsZero() {
		return Execution{}, false, fmt.Errorf("join preparation time is required")
	}
	specification, err := specificationFromRequest(request)
	if err != nil {
		return Execution{}, false, err
	}
	identifier, err := artifactID(specification)
	if err != nil {
		return Execution{}, false, err
	}
	path, err := store.executionPath(specification.ExecutionID)
	if err != nil {
		return Execution{}, false, err
	}

	lock, err := store.lock()
	if err != nil {
		return Execution{}, false, err
	}
	defer unlock(lock)

	previous, found, err := readExecution(path)
	if err != nil {
		return Execution{}, false, err
	}
	if found {
		if previous.ArtifactID == identifier &&
			reflect.DeepEqual(previous.Specification, specification) {
			return cloneExecution(previous), false, nil
		}
		return Execution{}, false, &ConflictError{ExecutionID: specification.ExecutionID}
	}

	preparedAt = preparedAt.UTC()
	execution := Execution{
		Version:       ExecutionVersionV1,
		ExecutionID:   specification.ExecutionID,
		ArtifactID:    identifier,
		Specification: specification,
		State:         Prepared,
		PreparedAt:    preparedAt,
		UpdatedAt:     preparedAt,
	}
	if err := store.writeExecution(path, execution); err != nil {
		return Execution{}, false, err
	}
	return cloneExecution(execution), true, nil
}

func (store *Store) Get(executionID string) (Execution, bool, error) {
	path, err := store.executionPath(executionID)
	if err != nil {
		return Execution{}, false, err
	}
	execution, found, err := readExecution(path)
	if err != nil {
		return Execution{}, false, err
	}
	if found && execution.ExecutionID != executionID {
		return Execution{}, false, fmt.Errorf(
			"stored join execution has unexpected ID %q",
			execution.ExecutionID,
		)
	}
	return cloneExecution(execution), found, nil
}

func (store *Store) FindByArtifactID(artifactID string) (Execution, bool, error) {
	if err := validateArtifactID(artifactID); err != nil {
		return Execution{}, false, err
	}
	entries, err := os.ReadDir(store.executionsDir)
	if err != nil {
		return Execution{}, false, fmt.Errorf("read join executions: %w", err)
	}

	var match *Execution
	for _, entry := range entries {
		if isTemporaryExecutionName(entry.Name()) {
			continue
		}
		path := filepath.Join(store.executionsDir, entry.Name())
		execution, found, err := readExecution(path)
		if err != nil {
			return Execution{}, false, err
		}
		if !found {
			return Execution{}, false, fmt.Errorf(
				"join execution %q disappeared during artifact lookup",
				entry.Name(),
			)
		}
		expectedPath, err := store.executionPath(execution.ExecutionID)
		if err != nil {
			return Execution{}, false, err
		}
		if filepath.Base(expectedPath) != entry.Name() {
			return Execution{}, false, fmt.Errorf(
				"join execution file %q does not match execution %q",
				entry.Name(),
				execution.ExecutionID,
			)
		}
		if execution.ArtifactID != artifactID {
			continue
		}
		if match != nil {
			return Execution{}, false, fmt.Errorf(
				"multiple join executions contain artifact %q",
				artifactID,
			)
		}
		matched := cloneExecution(execution)
		match = &matched
	}
	if match == nil {
		return Execution{}, false, nil
	}
	return cloneExecution(*match), true, nil
}

func (store *Store) MarkStaged(
	executionID string,
	artifactID string,
	staged StagedArtifact,
	updatedAt time.Time,
) (Execution, bool, error) {
	return store.update(
		executionID,
		updatedAt,
		func(previous Execution) (Execution, bool, error) {
			if err := matchArtifact(previous, artifactID, staged.Fingerprint); err != nil {
				return Execution{}, false, err
			}
			switch previous.State {
			case Prepared:
				previous.State = Staged
				previous.Staged = &staged
				return previous, true, nil
			case Staged:
				if previous.Staged != nil && reflect.DeepEqual(*previous.Staged, staged) {
					return previous, false, nil
				}
				return Execution{}, false, fmt.Errorf(
					"execution %q is already bound to different staged evidence",
					executionID,
				)
			default:
				return Execution{}, false, fmt.Errorf(
					"cannot stage join execution from state %q",
					previous.State,
				)
			}
		},
	)
}

func (store *Store) MarkStageFailed(
	executionID string,
	reason workercontracts.StageJoinFailureReason,
	updatedAt time.Time,
) (Execution, bool, error) {
	failure := StageFailure{Reason: reason}
	if err := validateFailure(failure); err != nil {
		return Execution{}, false, err
	}
	return store.update(
		executionID,
		updatedAt,
		func(previous Execution) (Execution, bool, error) {
			switch previous.State {
			case Prepared:
				previous.State = Failed
				previous.Failure = &failure
				return previous, true, nil
			case Failed:
				if previous.Failure != nil && *previous.Failure == failure {
					return previous, false, nil
				}
				return Execution{}, false, fmt.Errorf(
					"execution %q is already bound to a different failure",
					executionID,
				)
			default:
				return Execution{}, false, fmt.Errorf(
					"cannot fail join execution from state %q",
					previous.State,
				)
			}
		},
	)
}

func (store *Store) MarkPublished(
	executionID string,
	artifactID string,
	fingerprint string,
	published PublishedArtifact,
	updatedAt time.Time,
) (Execution, bool, error) {
	return store.update(
		executionID,
		updatedAt,
		func(previous Execution) (Execution, bool, error) {
			if err := matchArtifact(previous, artifactID, fingerprint); err != nil {
				return Execution{}, false, err
			}
			switch previous.State {
			case Staged:
				previous.State = Published
				previous.Published = &published
				return previous, true, nil
			case Published:
				if previous.Published != nil && reflect.DeepEqual(*previous.Published, published) {
					return previous, false, nil
				}
				return Execution{}, false, fmt.Errorf(
					"execution %q is already bound to a different published artifact",
					executionID,
				)
			default:
				return Execution{}, false, fmt.Errorf(
					"cannot publish join execution from state %q",
					previous.State,
				)
			}
		},
	)
}

func (store *Store) MarkDiscarded(
	executionID string,
	artifactID string,
	fingerprint string,
	updatedAt time.Time,
) (Execution, bool, error) {
	return store.update(
		executionID,
		updatedAt,
		func(previous Execution) (Execution, bool, error) {
			if err := matchArtifact(previous, artifactID, fingerprint); err != nil {
				return Execution{}, false, err
			}
			switch previous.State {
			case Staged:
				previous.State = Discarded
				return previous, true, nil
			case Discarded:
				return previous, false, nil
			default:
				return Execution{}, false, fmt.Errorf(
					"cannot discard join execution from state %q",
					previous.State,
				)
			}
		},
	)
}

func (store *Store) update(
	executionID string,
	updatedAt time.Time,
	update func(Execution) (Execution, bool, error),
) (Execution, bool, error) {
	if updatedAt.IsZero() {
		return Execution{}, false, fmt.Errorf("join update time is required")
	}
	path, err := store.executionPath(executionID)
	if err != nil {
		return Execution{}, false, err
	}
	lock, err := store.lock()
	if err != nil {
		return Execution{}, false, err
	}
	defer unlock(lock)

	previous, found, err := readExecution(path)
	if err != nil {
		return Execution{}, false, err
	}
	if !found {
		return Execution{}, false, fmt.Errorf(
			"join execution %q is not prepared",
			executionID,
		)
	}
	if updatedAt.Before(previous.PreparedAt) {
		return Execution{}, false, fmt.Errorf("join update time precedes preparation")
	}
	next, changed, err := update(cloneExecution(previous))
	if err != nil {
		return Execution{}, false, err
	}
	if !changed {
		return cloneExecution(previous), false, nil
	}
	next.UpdatedAt = updatedAt.UTC()
	if err := store.writeExecution(path, next); err != nil {
		return Execution{}, false, err
	}
	return cloneExecution(next), true, nil
}

func matchArtifact(execution Execution, artifactID string, fingerprint string) error {
	if execution.ArtifactID != artifactID {
		return fmt.Errorf("artifact ID does not match join execution %q", execution.ExecutionID)
	}
	if execution.Staged != nil && execution.Staged.Fingerprint != fingerprint {
		return fmt.Errorf(
			"artifact fingerprint does not match join execution %q",
			execution.ExecutionID,
		)
	}
	return nil
}

func (store *Store) executionPath(executionID string) (string, error) {
	if err := validateExecutionID(executionID); err != nil {
		return "", err
	}
	digest := sha256.New()
	_, _ = digest.Write([]byte(executionPathDomain))
	_, _ = digest.Write([]byte(executionID))
	return filepath.Join(
		store.executionsDir,
		hex.EncodeToString(digest.Sum(nil))+".json",
	), nil
}

func validateExecutionID(executionID string) error {
	_, err := workercontracts.EncodeDiscardRequest(workercontracts.DiscardRequestV1{
		ArtifactFingerprint: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
		ArtifactID:          "artifact:state-validation",
		Operation:           workercontracts.DiscardV1,
		RequestID:           executionID,
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	})
	if err != nil {
		return fmt.Errorf("invalid execution ID %q: %w", executionID, err)
	}
	return nil
}

func validateArtifactID(artifactID string) error {
	digest := strings.TrimPrefix(artifactID, artifactIDPrefix)
	if digest == artifactID || len(digest) != sha256.Size*2 {
		return fmt.Errorf("invalid join artifact ID %q", artifactID)
	}
	decoded, err := hex.DecodeString(digest)
	if err != nil || hex.EncodeToString(decoded) != digest {
		return fmt.Errorf("invalid join artifact ID %q", artifactID)
	}
	return nil
}

func isTemporaryExecutionName(name string) bool {
	return strings.HasPrefix(name, ".state-") && strings.HasSuffix(name, ".tmp")
}

func (store *Store) lock() (*os.File, error) {
	path := filepath.Join(store.root, lockFileName)
	fileDescriptor, err := unix.Open(
		path,
		unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW,
		0o600,
	)
	if err != nil {
		return nil, fmt.Errorf("open join state lock: %w", err)
	}
	lock := os.NewFile(uintptr(fileDescriptor), path)
	if err := lock.Chmod(0o600); err != nil {
		lock.Close()
		return nil, fmt.Errorf("set join state lock permissions: %w", err)
	}
	if err := unix.Flock(fileDescriptor, unix.LOCK_EX); err != nil {
		lock.Close()
		return nil, fmt.Errorf("lock join state: %w", err)
	}
	return lock, nil
}

func unlock(lock *os.File) {
	_ = unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	_ = lock.Close()
}

func readExecution(path string) (Execution, bool, error) {
	fileDescriptor, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if errors.Is(err, os.ErrNotExist) {
		return Execution{}, false, nil
	}
	if err != nil {
		return Execution{}, false, fmt.Errorf("open join execution: %w", err)
	}
	file := os.NewFile(uintptr(fileDescriptor), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return Execution{}, true, fmt.Errorf("inspect join execution: %w", err)
	}
	if !info.Mode().IsRegular() {
		return Execution{}, true, fmt.Errorf("join execution is not a regular file")
	}
	data, err := io.ReadAll(io.LimitReader(file, MaxExecutionBytes+1))
	if err != nil {
		return Execution{}, true, fmt.Errorf("read join execution: %w", err)
	}
	execution, err := DecodeExecution(data)
	if err != nil {
		return Execution{}, true, fmt.Errorf("validate stored join execution: %w", err)
	}
	return execution, true, nil
}

func (store *Store) writeExecution(path string, execution Execution) error {
	data, err := EncodeExecution(execution)
	if err != nil {
		return err
	}
	if err := privatefile.Replace(store.executionsDir, path, data); err != nil {
		return fmt.Errorf("store join execution: %w", err)
	}
	return nil
}

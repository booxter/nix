package lidarrrepair

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"time"

	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/privatefile"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
	"golang.org/x/sys/unix"
)

const (
	caseRecordVersion     = "lidarr-repair-case/v1"
	planningResultVersion = "lidarr-repair-planning/v1"
	observationVersion    = "lidarr-repair-observation/v1"
	stateLockName         = ".lock"
)

type caseRecord struct {
	Version           string          `json:"version"`
	CaseID            string          `json:"case_id"`
	QueueID           int64           `json:"queue_id"`
	SourceKind        SourceKind      `json:"source_kind"`
	SourcePath        string          `json:"source_path"`
	SourceFingerprint string          `json:"source_fingerprint"`
	WorkspaceRoot     string          `json:"workspace_root"`
	Case              json.RawMessage `json:"case"`
	Bindings          []ImportBinding `json:"bindings"`
}

type planningResult struct {
	Version     string                  `json:"version"`
	CaseID      string                  `json:"case_id"`
	Attempts    uint64                  `json:"attempts"`
	AttemptedAt time.Time               `json:"attempted_at"`
	RetryAfter  *time.Time              `json:"retry_after,omitempty"`
	Failure     *planningrunner.Failure `json:"failure,omitempty"`
	Decision    json.RawMessage         `json:"decision,omitempty"`
}

type observationRecord struct {
	Version string `json:"version"`
	QueueID int64  `json:"queue_id"`
	CaseID  string `json:"case_id"`
}

func (result planningResult) status() planningrunner.Status {
	return planningrunner.Status{
		Attempts: result.Attempts, RetryAfter: result.RetryAfter, Decided: len(result.Decision) != 0,
	}
}

func (store *Store) PutCase(record Record) (bool, error) {
	stored, err := newCaseRecord(record)
	if err != nil {
		return false, err
	}
	data, err := encodeCaseRecord(stored)
	if err != nil {
		return false, err
	}
	path, err := store.casePath(stored.CaseID)
	if err != nil {
		return false, err
	}
	lock, err := store.lock()
	if err != nil {
		return false, err
	}
	defer unlockState(lock)

	found, err := equivalentCaseAt(path, stored)
	if err != nil {
		return false, err
	}
	if found {
		return false, store.putObservationLocked(stored.QueueID, stored.CaseID)
	}
	temporary, err := os.CreateTemp(store.casesDir, ".case-*.tmp")
	if err != nil {
		return false, fmt.Errorf("create temporary Lidarr case record: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return false, fmt.Errorf("set temporary Lidarr case permissions: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return false, fmt.Errorf("write temporary Lidarr case record: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return false, fmt.Errorf("sync temporary Lidarr case record: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return false, fmt.Errorf("close temporary Lidarr case record: %w", err)
	}
	if err := os.Link(temporaryPath, path); err != nil {
		if !errors.Is(err, os.ErrExist) {
			return false, fmt.Errorf("publish Lidarr case record: %w", err)
		}
		found, compareErr := equivalentCaseAt(path, stored)
		if compareErr != nil {
			return false, compareErr
		}
		if !found {
			return false, fmt.Errorf("Lidarr case record disappeared during publication")
		}
		if err := privatefile.SyncDirectory(store.casesDir); err != nil {
			return false, err
		}
		return false, store.putObservationLocked(stored.QueueID, stored.CaseID)
	}
	if err := os.Remove(temporaryPath); err != nil {
		return false, fmt.Errorf("remove temporary Lidarr case record: %w", err)
	}
	if err := privatefile.SyncDirectory(store.casesDir); err != nil {
		return false, fmt.Errorf("sync Lidarr case records: %w", err)
	}
	if err := store.putObservationLocked(stored.QueueID, stored.CaseID); err != nil {
		return false, err
	}
	return true, nil
}

func (store *Store) GetStatus(caseID string) (planningrunner.Status, bool, error) {
	result, found, err := store.readPlanningResult(caseID)
	return result.status(), found, err
}

func (store *Store) GetDecision(caseID string) (lidarrcontracts.Decision, error) {
	result, found, err := store.readPlanningResult(caseID)
	if err != nil {
		return lidarrcontracts.Decision{}, err
	}
	if !found || len(result.Decision) == 0 {
		return lidarrcontracts.Decision{}, fmt.Errorf(
			"case %q has no stored planning decision", caseID,
		)
	}
	decision, err := lidarrcontracts.DecodeDecision(result.Decision)
	if err != nil {
		return lidarrcontracts.Decision{}, err
	}
	return decision, nil
}

func (store *Store) PutFailure(
	caseID string,
	failure planningrunner.Failure,
	attemptedAt time.Time,
	retryAfter time.Time,
) (planningrunner.Status, bool, error) {
	result, changed, err := store.updatePlanningResult(caseID, func(
		previous planningResult,
		found bool,
	) (planningResult, bool, error) {
		if found && len(previous.Decision) != 0 {
			return previous, false, nil
		}
		attempts, err := nextAttempts(previous, found)
		if err != nil {
			return planningResult{}, false, err
		}
		return planningResult{
			Version: planningResultVersion, CaseID: caseID, Attempts: attempts,
			AttemptedAt: attemptedAt.UTC(), RetryAfter: timePointer(retryAfter.UTC()),
			Failure: &failure,
		}, true, nil
	})
	return result.status(), changed, err
}

func (store *Store) PutDecision(
	caseID string,
	decision lidarrcontracts.Decision,
	attemptedAt time.Time,
) (planningrunner.Status, bool, error) {
	encoded, err := lidarrcontracts.EncodeDecision(decision)
	if err != nil {
		return planningrunner.Status{}, false, err
	}
	if decision.CaseID() != caseID {
		return planningrunner.Status{}, false, fmt.Errorf(
			"Lidarr planning decision case ID does not match its record",
		)
	}
	result, changed, err := store.updatePlanningResult(caseID, func(
		previous planningResult,
		found bool,
	) (planningResult, bool, error) {
		if found && len(previous.Decision) != 0 {
			if bytes.Equal(previous.Decision, encoded) {
				return previous, false, nil
			}
			return planningResult{}, false, fmt.Errorf(
				"case ID %q is already bound to a different Lidarr planning decision", caseID,
			)
		}
		attempts, err := nextAttempts(previous, found)
		if err != nil {
			return planningResult{}, false, err
		}
		return planningResult{
			Version: planningResultVersion, CaseID: caseID, Attempts: attempts,
			AttemptedAt: attemptedAt.UTC(), Decision: encoded,
		}, true, nil
	})
	return result.status(), changed, err
}

func (store *Store) updatePlanningResult(
	caseID string,
	update func(planningResult, bool) (planningResult, bool, error),
) (planningResult, bool, error) {
	lock, err := store.lock()
	if err != nil {
		return planningResult{}, false, err
	}
	defer unlockState(lock)
	if _, found, err := store.readCase(caseID); err != nil {
		return planningResult{}, false, err
	} else if !found {
		return planningResult{}, false, fmt.Errorf("case %q is not stored", caseID)
	}
	previous, found, err := store.readPlanningResult(caseID)
	if err != nil {
		return planningResult{}, false, err
	}
	result, changed, err := update(previous, found)
	if err != nil || !changed {
		return result, changed, err
	}
	data, err := encodePlanningResult(result)
	if err != nil {
		return planningResult{}, false, err
	}
	path, err := store.planningPath(caseID)
	if err != nil {
		return planningResult{}, false, err
	}
	if err := privatefile.Replace(store.planningDir, path, data); err != nil {
		return planningResult{}, false, err
	}
	return result, true, nil
}

func (store *Store) latestPlanned(queueID int64) (Record, bool, error) {
	if queueID <= 0 {
		return Record{}, false, fmt.Errorf("Lidarr queue ID must be positive")
	}
	path, err := store.observationPath(queueID)
	if err != nil {
		return Record{}, false, err
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Record{}, false, nil
	}
	if err != nil {
		return Record{}, false, fmt.Errorf("read Lidarr observation record: %w", err)
	}
	var observation observationRecord
	if err := decodeStrictState(data, &observation); err != nil {
		return Record{}, false, fmt.Errorf("decode Lidarr observation record: %w", err)
	}
	if observation.Version != observationVersion || observation.QueueID != queueID ||
		!stateFingerprint.MatchString(observation.CaseID) {
		return Record{}, false, fmt.Errorf("Lidarr observation record identity is invalid")
	}
	latest, found, err := store.readCase(observation.CaseID)
	if err != nil || !found {
		return Record{}, false, err
	}
	if latest.QueueID != queueID {
		return Record{}, false, fmt.Errorf("Lidarr observation points to another queue")
	}
	result, found, err := store.readPlanningResult(observation.CaseID)
	if err != nil || !found || len(result.Decision) == 0 {
		return Record{}, false, err
	}
	return latest.join(result.Decision), true, nil
}

func (store *Store) putObservationLocked(queueID int64, caseID string) error {
	path, err := store.observationPath(queueID)
	if err != nil {
		return err
	}
	record := observationRecord{Version: observationVersion, QueueID: queueID, CaseID: caseID}
	data, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("encode Lidarr observation record: %w", err)
	}
	if err := privatefile.Replace(store.observationsDir, path, data); err != nil {
		return fmt.Errorf("store Lidarr observation record: %w", err)
	}
	return nil
}

func (store *Store) migrateLegacyRecords() error {
	entries, err := os.ReadDir(store.directory)
	if err != nil {
		return fmt.Errorf("read Lidarr state directory: %w", err)
	}
	names := make([]string, 0)
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasPrefix(entry.Name(), "queue-v3-") &&
			strings.HasSuffix(entry.Name(), ".json") {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	for _, name := range names {
		data, err := os.ReadFile(filepath.Join(store.directory, name))
		if err != nil {
			return fmt.Errorf("read legacy Lidarr repair state: %w", err)
		}
		record, err := decodeRecord(data)
		if err != nil {
			return fmt.Errorf("migrate legacy Lidarr repair state %q: %w", name, err)
		}
		if err := store.Put(record); err != nil {
			return fmt.Errorf("migrate legacy Lidarr repair state %q: %w", name, err)
		}
	}
	return nil
}

func newCaseRecord(record Record) (caseRecord, error) {
	repairCase, err := lidarrcontracts.DecodeCase(record.Case)
	if err != nil {
		return caseRecord{}, fmt.Errorf("decode stored Lidarr repair case: %w", err)
	}
	stored := caseRecord{
		Version: caseRecordVersion, CaseID: repairCase.CaseID, QueueID: record.QueueID,
		SourceKind: record.SourceKind, SourcePath: record.SourcePath,
		SourceFingerprint: record.SourceFingerprint, WorkspaceRoot: record.WorkspaceRoot,
		Case:     append(json.RawMessage(nil), record.Case...),
		Bindings: append([]ImportBinding(nil), record.Bindings...),
	}
	if err := validateCaseRecord(stored); err != nil {
		return caseRecord{}, err
	}
	return stored, nil
}

func (stored caseRecord) join(decision json.RawMessage) Record {
	return Record{
		Version: stateVersion, QueueID: stored.QueueID, SourceKind: stored.SourceKind,
		SourcePath: stored.SourcePath, SourceFingerprint: stored.SourceFingerprint,
		WorkspaceRoot: stored.WorkspaceRoot, Case: append(json.RawMessage(nil), stored.Case...),
		Decision: append(json.RawMessage(nil), decision...),
		Bindings: append([]ImportBinding(nil), stored.Bindings...),
	}
}

func recordCaseID(record Record) (string, error) {
	repairCase, err := lidarrcontracts.DecodeCase(record.Case)
	if err != nil {
		return "", err
	}
	return repairCase.CaseID, nil
}

func encodeCaseRecord(record caseRecord) ([]byte, error) {
	if err := validateCaseRecord(record); err != nil {
		return nil, err
	}
	data, err := json.Marshal(record)
	if err != nil {
		return nil, fmt.Errorf("encode Lidarr case record: %w", err)
	}
	return data, nil
}

func decodeCaseRecord(data []byte) (caseRecord, error) {
	var record caseRecord
	if err := decodeStrictState(data, &record); err != nil {
		return caseRecord{}, fmt.Errorf("decode Lidarr case record: %w", err)
	}
	if err := validateCaseRecord(record); err != nil {
		return caseRecord{}, err
	}
	return record, nil
}

func validateCaseRecord(record caseRecord) error {
	if record.Version != caseRecordVersion || record.QueueID <= 0 ||
		(record.SourceKind != SourceTarAudio && record.SourceKind != SourceDirectoryAudio) ||
		record.SourcePath == "" || !filepath.IsAbs(record.SourcePath) ||
		filepath.Clean(record.SourcePath) != record.SourcePath ||
		!stateFingerprint.MatchString(record.SourceFingerprint) ||
		record.WorkspaceRoot == "" || !filepath.IsAbs(record.WorkspaceRoot) ||
		filepath.Clean(record.WorkspaceRoot) != record.WorkspaceRoot {
		return fmt.Errorf("Lidarr case record identity is invalid")
	}
	repairCase, err := lidarrcontracts.DecodeCase(record.Case)
	if err != nil {
		return fmt.Errorf("decode stored Lidarr repair case: %w", err)
	}
	if repairCase.CaseID != record.CaseID || repairCase.Queue.QueueID != record.QueueID {
		return fmt.Errorf("stored Lidarr case record has mismatched identities")
	}
	seen := make(map[string]struct{}, len(record.Bindings))
	for _, binding := range record.Bindings {
		if binding.ArtifactID == "" || binding.Path == "" || !filepath.IsAbs(binding.Path) ||
			filepath.Clean(binding.Path) != binding.Path || binding.DownloadID == "" {
			return fmt.Errorf("stored Lidarr import binding is invalid")
		}
		if _, duplicate := seen[binding.ArtifactID]; duplicate {
			return fmt.Errorf("stored Lidarr import binding is duplicated")
		}
		seen[binding.ArtifactID] = struct{}{}
	}
	return nil
}

func equivalentCaseAt(path string, wanted caseRecord) (bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("read existing Lidarr case record: %w", err)
	}
	existing, err := decodeCaseRecord(data)
	if err != nil {
		return true, err
	}
	left, err := lidarrcontracts.DecodeCase(existing.Case)
	if err != nil {
		return true, err
	}
	right, err := lidarrcontracts.DecodeCase(wanted.Case)
	if err != nil {
		return true, err
	}
	left.ObservedAt = time.Time{}
	right.ObservedAt = time.Time{}
	existing.Case = nil
	wanted.Case = nil
	if !reflect.DeepEqual(existing, wanted) || !reflect.DeepEqual(left, right) {
		return true, fmt.Errorf(
			"case ID %q is already bound to different Lidarr local state", wanted.CaseID,
		)
	}
	return true, nil
}

func (store *Store) readCase(caseID string) (caseRecord, bool, error) {
	path, err := store.casePath(caseID)
	if err != nil {
		return caseRecord{}, false, err
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return caseRecord{}, false, nil
	}
	if err != nil {
		return caseRecord{}, false, fmt.Errorf("read Lidarr case record: %w", err)
	}
	record, err := decodeCaseRecord(data)
	return record, true, err
}

func encodePlanningResult(result planningResult) ([]byte, error) {
	if err := validatePlanningResult(result); err != nil {
		return nil, err
	}
	data, err := json.Marshal(result)
	if err != nil {
		return nil, fmt.Errorf("encode Lidarr planning result: %w", err)
	}
	return data, nil
}

func decodePlanningResult(data []byte) (planningResult, error) {
	var result planningResult
	if err := decodeStrictState(data, &result); err != nil {
		return planningResult{}, fmt.Errorf("decode Lidarr planning result: %w", err)
	}
	if err := validatePlanningResult(result); err != nil {
		return planningResult{}, err
	}
	return result, nil
}

func validatePlanningResult(result planningResult) error {
	if result.Version != planningResultVersion || !stateFingerprint.MatchString(result.CaseID) ||
		result.Attempts == 0 || result.AttemptedAt.IsZero() {
		return fmt.Errorf("Lidarr planning result identity is invalid")
	}
	hasDecision := len(result.Decision) != 0
	hasFailure := result.Failure != nil
	if hasDecision == hasFailure {
		return fmt.Errorf("Lidarr planning result must contain exactly one decision or failure")
	}
	if hasDecision {
		if result.RetryAfter != nil {
			return fmt.Errorf("successful Lidarr planning result cannot have a retry time")
		}
		decision, err := lidarrcontracts.DecodeDecision(result.Decision)
		if err != nil {
			return err
		}
		if decision.CaseID() != result.CaseID {
			return fmt.Errorf("Lidarr planning decision case ID does not match its record")
		}
		return nil
	}
	if result.RetryAfter == nil || !result.RetryAfter.After(result.AttemptedAt) ||
		!planningrunner.ValidFailure(*result.Failure) {
		return fmt.Errorf("failed Lidarr planning result is invalid")
	}
	return nil
}

func (store *Store) readPlanningResult(caseID string) (planningResult, bool, error) {
	path, err := store.planningPath(caseID)
	if err != nil {
		return planningResult{}, false, err
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return planningResult{}, false, nil
	}
	if err != nil {
		return planningResult{}, false, fmt.Errorf("read Lidarr planning result: %w", err)
	}
	result, err := decodePlanningResult(data)
	return result, true, err
}

func nextAttempts(previous planningResult, found bool) (uint64, error) {
	if !found {
		return 1, nil
	}
	if previous.Attempts == math.MaxUint64 {
		return 0, fmt.Errorf("Lidarr planning attempt count overflow")
	}
	return previous.Attempts + 1, nil
}

func decodeStrictState(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("multiple JSON values")
		}
		return fmt.Errorf("read trailing JSON: %w", err)
	}
	return nil
}

func (store *Store) casePath(caseID string) (string, error) {
	digest, err := stateDigest(caseID)
	if err != nil {
		return "", err
	}
	return filepath.Join(store.casesDir, digest+".json"), nil
}

func (store *Store) planningPath(caseID string) (string, error) {
	digest, err := stateDigest(caseID)
	if err != nil {
		return "", err
	}
	return filepath.Join(store.planningDir, digest+".json"), nil
}

func (store *Store) observationPath(queueID int64) (string, error) {
	if queueID <= 0 {
		return "", fmt.Errorf("Lidarr queue ID must be positive")
	}
	return filepath.Join(store.observationsDir, fmt.Sprintf("queue-%d.json", queueID)), nil
}

func stateDigest(caseID string) (string, error) {
	if !stateFingerprint.MatchString(caseID) {
		return "", fmt.Errorf("invalid Lidarr case ID %q", caseID)
	}
	return strings.TrimPrefix(caseID, "sha256:"), nil
}

func (store *Store) lock() (*os.File, error) {
	path := filepath.Join(store.directory, stateLockName)
	fd, err := unix.Open(
		path, unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0o600,
	)
	if err != nil {
		return nil, fmt.Errorf("open Lidarr state lock: %w", err)
	}
	lock := os.NewFile(uintptr(fd), path)
	if err := lock.Chmod(0o600); err != nil {
		lock.Close()
		return nil, fmt.Errorf("set Lidarr state lock permissions: %w", err)
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		lock.Close()
		return nil, fmt.Errorf("lock Lidarr state: %w", err)
	}
	return lock, nil
}

func unlockState(lock *os.File) {
	_ = unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	_ = lock.Close()
}

func timePointer(value time.Time) *time.Time {
	return &value
}

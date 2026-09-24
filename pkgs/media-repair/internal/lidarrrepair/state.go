package lidarrrepair

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/planningstate"
	"github.com/booxter/nix-config/media-repair/internal/privatefile"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
	"golift.io/starr"
)

const stateVersion = "lidarr-repair-state/v3"

var stateFingerprint = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

type SourceKind string

const (
	SourceTarAudio       SourceKind = "tar_audio_v1"
	SourceDirectoryAudio SourceKind = "directory_audio_v1"
)

type ImportBinding struct {
	ArtifactID              string         `json:"artifact_id"`
	Path                    string         `json:"path"`
	Quality                 *starr.Quality `json:"quality"`
	IndexerFlags            int            `json:"indexer_flags"`
	DownloadID              string         `json:"download_id"`
	DisableReleaseSwitching bool           `json:"disable_release_switching"`
}

type Record struct {
	Version           string          `json:"version"`
	QueueID           int64           `json:"queue_id"`
	SourceKind        SourceKind      `json:"source_kind"`
	SourcePath        string          `json:"source_path"`
	SourceFingerprint string          `json:"source_fingerprint"`
	WorkspaceRoot     string          `json:"workspace_root"`
	Case              json.RawMessage `json:"case"`
	Decision          json.RawMessage `json:"decision"`
	Bindings          []ImportBinding `json:"bindings"`
}

type Store struct {
	directory       string
	casesDir        string
	planningDir     string
	observationsDir string
	cases           *planningstate.CaseStore[caseRecord]
}

func NewStore(directory string) (*Store, error) {
	if directory == "" || !filepath.IsAbs(directory) || filepath.Clean(directory) != directory ||
		filepath.Dir(directory) == directory {
		return nil, fmt.Errorf("Lidarr state directory must be an absolute clean path")
	}
	if err := privatefile.EnsureDirectory(directory); err != nil {
		return nil, fmt.Errorf("prepare Lidarr state directory: %w", err)
	}
	casesDir := filepath.Join(directory, "cases")
	if err := privatefile.EnsureDirectory(casesDir); err != nil {
		return nil, fmt.Errorf("prepare Lidarr case records directory: %w", err)
	}
	planningDir := filepath.Join(directory, "planning")
	if err := privatefile.EnsureDirectory(planningDir); err != nil {
		return nil, fmt.Errorf("prepare Lidarr planning records directory: %w", err)
	}
	observationsDir := filepath.Join(directory, "observations")
	if err := privatefile.EnsureDirectory(observationsDir); err != nil {
		return nil, fmt.Errorf("prepare Lidarr observation records directory: %w", err)
	}
	store := &Store{
		directory: directory, casesDir: casesDir, planningDir: planningDir,
		observationsDir: observationsDir,
	}
	cases, err := planningstate.NewCaseStore(
		casesDir,
		func() (func(), error) {
			lock, lockErr := store.lock()
			if lockErr != nil {
				return nil, lockErr
			}
			return func() { unlockState(lock) }, nil
		},
		planningstate.CaseCodec[caseRecord]{
			CaseID:       func(record caseRecord) string { return record.CaseID },
			Encode:       encodeCaseRecord,
			Decode:       decodeCaseRecord,
			SameIdentity: sameLidarrCaseIdentity,
			Merge: func(stored, current caseRecord) (caseRecord, error) {
				return mergeLidarrCaseObservation(stored, current), nil
			},
		},
	)
	if err != nil {
		return nil, err
	}
	store.cases = cases
	if err := store.migrateLegacyRecords(); err != nil {
		return nil, err
	}
	return store, nil
}

func (store *Store) Get(queueID int64) (Record, bool, error) {
	return store.latestPlanned(queueID)
}

func (store *Store) Put(record Record) error {
	if _, err := encodeRecord(record); err != nil {
		return err
	}
	if _, err := store.PutCase(record); err != nil {
		return err
	}
	decision, err := lidarrcontracts.DecodeDecision(record.Decision)
	if err != nil {
		return err
	}
	caseID, err := recordCaseID(record)
	if err != nil {
		return err
	}
	_, _, err = store.PutDecision(caseID, decision, time.Now().UTC())
	return err
}

func (store *Store) path(queueID int64) (string, error) {
	if store == nil || store.directory == "" || queueID <= 0 {
		return "", fmt.Errorf("Lidarr repair state is not configured")
	}
	return filepath.Join(store.directory, fmt.Sprintf("queue-v3-%d.json", queueID)), nil
}

func encodeRecord(record Record) ([]byte, error) {
	if err := validateRecord(record); err != nil {
		return nil, err
	}
	data, err := json.Marshal(record)
	if err != nil {
		return nil, fmt.Errorf("encode Lidarr repair state: %w", err)
	}
	return data, nil
}

func decodeRecord(data []byte) (Record, error) {
	var record Record
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return Record{}, fmt.Errorf("decode Lidarr repair state: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Record{}, fmt.Errorf("decode Lidarr repair state trailing data")
	}
	if err := validateRecord(record); err != nil {
		return Record{}, err
	}
	return record, nil
}

func validateRecord(record Record) error {
	if record.Version != stateVersion || record.QueueID <= 0 ||
		(record.SourceKind != SourceTarAudio && record.SourceKind != SourceDirectoryAudio) ||
		record.SourcePath == "" || !filepath.IsAbs(record.SourcePath) ||
		filepath.Clean(record.SourcePath) != record.SourcePath ||
		!stateFingerprint.MatchString(record.SourceFingerprint) ||
		record.WorkspaceRoot == "" || !filepath.IsAbs(record.WorkspaceRoot) ||
		filepath.Clean(record.WorkspaceRoot) != record.WorkspaceRoot {
		return fmt.Errorf("Lidarr repair state identity is invalid")
	}
	repairCase, err := lidarrcontracts.DecodeCase(record.Case)
	if err != nil {
		return fmt.Errorf("decode stored Lidarr repair case: %w", err)
	}
	decision, err := lidarrcontracts.DecodeDecision(record.Decision)
	if err != nil {
		return fmt.Errorf("decode stored Lidarr repair decision: %w", err)
	}
	if decision.CaseID() != repairCase.CaseID || repairCase.Queue.QueueID != record.QueueID {
		return fmt.Errorf("stored Lidarr repair state has mismatched identities")
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

func bindingFromImport(
	artifactID string,
	item lidarr.ManualImport,
	downloadID string,
) ImportBinding {
	return ImportBinding{
		ArtifactID: artifactID, Path: item.Path, Quality: item.Quality,
		IndexerFlags: item.IndexerFlags, DownloadID: downloadID,
		DisableReleaseSwitching: item.DisableReleaseSwitching,
	}
}

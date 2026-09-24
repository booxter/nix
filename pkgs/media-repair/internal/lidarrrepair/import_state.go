package lidarrrepair

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/privatefile"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

const importExecutionVersion = "lidarr-repair-import/v1"

var legacyImportExecutionName = regexp.MustCompile(`^import-queue-[1-9][0-9]*\.json$`)

type ImportExecutionState string

const (
	ImportPrepared  ImportExecutionState = "import_prepared"
	ImportRequested ImportExecutionState = "import_requested"
	Imported        ImportExecutionState = "imported"
	ImportFailed    ImportExecutionState = "import_failed"
)

type ImportExecutionTrack struct {
	ArtifactID          string `json:"artifact_id"`
	ArtifactFingerprint string `json:"artifact_fingerprint"`
	TrackID             int64  `json:"track_id"`
	Path                string `json:"path"`
	DownloadID          string `json:"download_id"`
}

type ImportExecution struct {
	Version         string                 `json:"version"`
	CaseID          string                 `json:"case_id"`
	CapabilityID    string                 `json:"capability_id"`
	QueueID         int64                  `json:"queue_id"`
	ArtistID        int64                  `json:"artist_id"`
	AlbumID         int64                  `json:"album_id"`
	ReleaseID       int64                  `json:"release_id"`
	Tracks          []ImportExecutionTrack `json:"tracks"`
	State           ImportExecutionState   `json:"state"`
	HistoryIDBefore int64                  `json:"history_id_before"`
	PreparedAt      time.Time              `json:"prepared_at"`
	UpdatedAt       time.Time              `json:"updated_at"`
	CommandID       *int64                 `json:"command_id,omitempty"`
	Confirmations   []lidarr.ImportedTrack `json:"confirmations,omitempty"`
}

func (store *Store) GetImportExecution(caseID string) (ImportExecution, bool, error) {
	path, err := store.importExecutionPath(caseID)
	if err != nil {
		return ImportExecution{}, false, err
	}
	return store.readImportExecution(path)
}

func (store *Store) readImportExecution(path string) (ImportExecution, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return ImportExecution{}, false, nil
	}
	if err != nil {
		return ImportExecution{}, false, fmt.Errorf("read Lidarr import execution: %w", err)
	}
	record, err := decodeImportExecution(data)
	return record, true, err
}

func (store *Store) activeImportForQueue(
	queueID int64,
	exceptCaseID string,
) (ImportExecution, bool, error) {
	entries, err := os.ReadDir(store.importsDir)
	if err != nil {
		return ImportExecution{}, false, fmt.Errorf("read Lidarr import records: %w", err)
	}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		record, found, err := store.readImportExecution(filepath.Join(store.importsDir, entry.Name()))
		if err != nil {
			return ImportExecution{}, false, err
		}
		if found && record.QueueID == queueID && record.CaseID != exceptCaseID &&
			(record.State == ImportPrepared || record.State == ImportRequested) {
			return record, true, nil
		}
	}
	return ImportExecution{}, false, nil
}

func (store *Store) migrateLegacyImportExecutions() error {
	entries, err := os.ReadDir(store.directory)
	if err != nil {
		return fmt.Errorf("read Lidarr state directory: %w", err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !legacyImportExecutionName.MatchString(entry.Name()) {
			continue
		}
		source := filepath.Join(store.directory, entry.Name())
		data, err := os.ReadFile(source)
		if err != nil {
			return fmt.Errorf("read legacy Lidarr import execution: %w", err)
		}
		record, err := decodeImportExecution(data)
		if err != nil {
			return fmt.Errorf("decode legacy Lidarr import execution %q: %w", entry.Name(), err)
		}
		if entry.Name() != fmt.Sprintf("import-queue-%d.json", record.QueueID) {
			return fmt.Errorf("legacy Lidarr import execution has unexpected queue ID")
		}
		destination, err := store.importExecutionPath(record.CaseID)
		if err != nil {
			return err
		}
		existing, found, err := store.readImportExecution(destination)
		if err != nil {
			return err
		}
		if found && !reflect.DeepEqual(existing, record) {
			return fmt.Errorf("legacy Lidarr import execution conflicts with case ledger")
		}
		if !found {
			canonical, err := encodeImportExecution(record)
			if err != nil {
				return err
			}
			if err := privatefile.Replace(store.importsDir, destination, canonical); err != nil {
				return fmt.Errorf("migrate legacy Lidarr import execution: %w", err)
			}
		}
		if err := os.Remove(source); err != nil {
			return fmt.Errorf("remove migrated Lidarr import execution: %w", err)
		}
	}
	return nil
}

func (store *Store) PrepareImport(
	authorized AuthorizedImport,
	historyIDBefore int64,
	at time.Time,
) (ImportExecution, bool, error) {
	if err := store.validateImportAuthorization(authorized); err != nil {
		return ImportExecution{}, false, err
	}
	if historyIDBefore < 0 || at.IsZero() {
		return ImportExecution{}, false, fmt.Errorf("Lidarr import preparation is invalid")
	}
	unlock, err := store.lock()
	if err != nil {
		return ImportExecution{}, false, err
	}
	defer unlockState(unlock)

	path, err := store.importExecutionPath(authorized.CaseID)
	if err != nil {
		return ImportExecution{}, false, err
	}
	previous, found, err := store.readImportExecution(path)
	if err != nil {
		return ImportExecution{}, false, err
	}
	wanted := executionFromAuthorization(authorized, historyIDBefore, at)
	if found {
		if sameImportExecution(previous, wanted) {
			return previous, false, nil
		}
		return ImportExecution{}, false, fmt.Errorf("Lidarr case is already bound to a different import")
	}
	active, found, err := store.activeImportForQueue(authorized.QueueID, authorized.CaseID)
	if err != nil {
		return ImportExecution{}, false, err
	}
	if found {
		return ImportExecution{}, false, fmt.Errorf(
			"Lidarr queue %d has active import for case %q",
			authorized.QueueID,
			active.CaseID,
		)
	}
	if err := store.writeImportExecution(wanted); err != nil {
		return ImportExecution{}, false, err
	}
	return wanted, true, nil
}

func (store *Store) MarkImportRequested(
	caseID string,
	commandID int64,
	at time.Time,
) (ImportExecution, bool, error) {
	if commandID <= 0 {
		return ImportExecution{}, false, fmt.Errorf("Lidarr command ID must be positive")
	}
	return store.updateImportExecution(caseID, at, func(record ImportExecution) (ImportExecution, bool, error) {
		if record.State == ImportRequested && record.CommandID != nil && *record.CommandID == commandID {
			return record, false, nil
		}
		if record.State != ImportPrepared || record.CommandID != nil {
			return record, false, fmt.Errorf("Lidarr import is not prepared")
		}
		record.State = ImportRequested
		record.CommandID = &commandID
		return record, true, nil
	})
}

func (store *Store) MarkImported(
	caseID string,
	confirmations []lidarr.ImportedTrack,
	at time.Time,
) (ImportExecution, bool, error) {
	return store.updateImportExecution(caseID, at, func(record ImportExecution) (ImportExecution, bool, error) {
		if record.State == Imported {
			if reflect.DeepEqual(record.Confirmations, confirmations) {
				return record, false, nil
			}
			return record, false, fmt.Errorf("Lidarr import has different confirmations")
		}
		if record.State != ImportPrepared && record.State != ImportRequested {
			return record, false, fmt.Errorf("Lidarr import cannot be confirmed from state %q", record.State)
		}
		if err := validateConfirmations(record, confirmations); err != nil {
			return record, false, err
		}
		record.State = Imported
		record.Confirmations = append([]lidarr.ImportedTrack(nil), confirmations...)
		return record, true, nil
	})
}

func (store *Store) MarkImportFailed(
	caseID string,
	at time.Time,
) (ImportExecution, bool, error) {
	return store.updateImportExecution(caseID, at, func(record ImportExecution) (ImportExecution, bool, error) {
		if record.State == ImportFailed {
			return record, false, nil
		}
		if record.State != ImportRequested {
			return record, false, fmt.Errorf("Lidarr import is not requested")
		}
		record.State = ImportFailed
		return record, true, nil
	})
}

func (store *Store) updateImportExecution(
	caseID string,
	at time.Time,
	update func(ImportExecution) (ImportExecution, bool, error),
) (ImportExecution, bool, error) {
	if at.IsZero() {
		return ImportExecution{}, false, fmt.Errorf("Lidarr import update time is required")
	}
	unlock, err := store.lock()
	if err != nil {
		return ImportExecution{}, false, err
	}
	defer unlockState(unlock)
	path, err := store.importExecutionPath(caseID)
	if err != nil {
		return ImportExecution{}, false, err
	}
	record, found, err := store.readImportExecution(path)
	if err != nil {
		return ImportExecution{}, false, err
	}
	if !found {
		return ImportExecution{}, false, fmt.Errorf("Lidarr import for case %q is not prepared", caseID)
	}
	if at.Before(record.UpdatedAt) {
		return ImportExecution{}, false, fmt.Errorf("Lidarr import update time moved backwards")
	}
	updated, changed, err := update(record)
	if err != nil || !changed {
		return updated, changed, err
	}
	updated.UpdatedAt = at.UTC()
	if err := store.writeImportExecution(updated); err != nil {
		return ImportExecution{}, false, err
	}
	return updated, true, nil
}

func (store *Store) validateImportAuthorization(authorized AuthorizedImport) error {
	planned, found, err := store.Get(authorized.QueueID)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("Lidarr planned case for queue %d is absent", authorized.QueueID)
	}
	repairCase, err := lidarrcontracts.DecodeCase(planned.Case)
	if err != nil {
		return err
	}
	decision, err := lidarrcontracts.DecodeDecision(planned.Decision)
	if err != nil {
		return err
	}
	selected := decision.ImportMissingTracks
	if repairCase.CaseID != authorized.CaseID || selected == nil ||
		selected.CapabilityID != authorized.CapabilityID || selected.AlbumID != authorized.AlbumID ||
		selected.ReleaseID != authorized.ReleaseID || repairCase.Album.ArtistID != authorized.ArtistID ||
		len(selected.Mappings) != len(authorized.Tracks) {
		return fmt.Errorf("Lidarr import authorization does not match the stored plan")
	}
	selectedTracks := make(map[int64]string, len(selected.Mappings))
	for _, mapping := range selected.Mappings {
		selectedTracks[mapping.TrackID] = mapping.ArtifactID
	}
	for _, track := range authorized.Tracks {
		if selectedTracks[track.TrackID] != track.ArtifactID {
			return fmt.Errorf("Lidarr import authorization does not match the stored mappings")
		}
	}
	return nil
}

func executionFromAuthorization(
	authorized AuthorizedImport,
	historyIDBefore int64,
	at time.Time,
) ImportExecution {
	tracks := make([]ImportExecutionTrack, len(authorized.Tracks))
	for index, track := range authorized.Tracks {
		tracks[index] = ImportExecutionTrack{
			ArtifactID: track.ArtifactID, ArtifactFingerprint: track.ArtifactFingerprint,
			TrackID: track.TrackID, Path: track.Path, DownloadID: track.DownloadID,
		}
	}
	return ImportExecution{
		Version: importExecutionVersion, CaseID: authorized.CaseID,
		CapabilityID: authorized.CapabilityID, QueueID: authorized.QueueID,
		ArtistID: authorized.ArtistID, AlbumID: authorized.AlbumID, ReleaseID: authorized.ReleaseID,
		Tracks: tracks, State: ImportPrepared, HistoryIDBefore: historyIDBefore,
		PreparedAt: at.UTC(), UpdatedAt: at.UTC(),
	}
}

func sameImportExecution(previous, wanted ImportExecution) bool {
	return previous.Version == wanted.Version && previous.CaseID == wanted.CaseID &&
		previous.CapabilityID == wanted.CapabilityID && previous.QueueID == wanted.QueueID &&
		previous.ArtistID == wanted.ArtistID && previous.AlbumID == wanted.AlbumID &&
		previous.ReleaseID == wanted.ReleaseID && reflect.DeepEqual(previous.Tracks, wanted.Tracks)
}

func validateConfirmations(record ImportExecution, confirmations []lidarr.ImportedTrack) error {
	if len(confirmations) != len(record.Tracks) {
		return fmt.Errorf("Lidarr import confirmations do not cover every track")
	}
	byTrack := make(map[int64]lidarr.ImportedTrack, len(confirmations))
	for _, confirmation := range confirmations {
		if _, duplicate := byTrack[confirmation.TrackID]; duplicate {
			return fmt.Errorf("Lidarr import confirmation track %d is duplicated", confirmation.TrackID)
		}
		byTrack[confirmation.TrackID] = confirmation
	}
	for _, track := range record.Tracks {
		confirmation, found := byTrack[track.TrackID]
		if !found || confirmation.AlbumID != record.AlbumID ||
			confirmation.ArtistID != record.ArtistID ||
			confirmation.DroppedPath != track.Path || confirmation.HistoryID <= record.HistoryIDBefore ||
			confirmation.OccurredAt.Before(record.PreparedAt) {
			return fmt.Errorf("Lidarr import confirmation for track %d does not match", track.TrackID)
		}
	}
	return nil
}

func (store *Store) importExecutionPath(caseID string) (string, error) {
	if store == nil || store.importsDir == "" {
		return "", fmt.Errorf("Lidarr import state is not configured")
	}
	digest, err := stateDigest(caseID)
	if err != nil {
		return "", err
	}
	return filepath.Join(store.importsDir, digest+".json"), nil
}

func (store *Store) writeImportExecution(record ImportExecution) error {
	data, err := encodeImportExecution(record)
	if err != nil {
		return err
	}
	path, err := store.importExecutionPath(record.CaseID)
	if err != nil {
		return err
	}
	return privatefile.Replace(store.importsDir, path, data)
}

func encodeImportExecution(record ImportExecution) ([]byte, error) {
	if err := validateImportExecution(record); err != nil {
		return nil, err
	}
	data, err := json.Marshal(record)
	if err != nil {
		return nil, fmt.Errorf("encode Lidarr import execution: %w", err)
	}
	return data, nil
}

func decodeImportExecution(data []byte) (ImportExecution, error) {
	var record ImportExecution
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return ImportExecution{}, fmt.Errorf("decode Lidarr import execution: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return ImportExecution{}, fmt.Errorf("decode Lidarr import execution trailing data")
	}
	if err := validateImportExecution(record); err != nil {
		return ImportExecution{}, err
	}
	return record, nil
}

func validateImportExecution(record ImportExecution) error {
	if record.Version != importExecutionVersion || !stateFingerprint.MatchString(record.CaseID) ||
		record.CapabilityID == "" || record.QueueID <= 0 || record.ArtistID <= 0 ||
		record.AlbumID <= 0 || record.ReleaseID <= 0 || len(record.Tracks) == 0 ||
		record.HistoryIDBefore < 0 || record.PreparedAt.IsZero() || record.UpdatedAt.IsZero() ||
		record.UpdatedAt.Before(record.PreparedAt) {
		return fmt.Errorf("Lidarr import execution identity is invalid")
	}
	seenArtifacts := make(map[string]struct{}, len(record.Tracks))
	seenTracks := make(map[int64]struct{}, len(record.Tracks))
	for _, track := range record.Tracks {
		if track.ArtifactID == "" || track.ArtifactFingerprint == "" || track.TrackID <= 0 ||
			track.Path == "" || !filepath.IsAbs(track.Path) || filepath.Clean(track.Path) != track.Path ||
			track.DownloadID == "" {
			return fmt.Errorf("Lidarr import execution track is invalid")
		}
		if _, duplicate := seenArtifacts[track.ArtifactID]; duplicate {
			return fmt.Errorf("Lidarr import execution artifact is duplicated")
		}
		if _, duplicate := seenTracks[track.TrackID]; duplicate {
			return fmt.Errorf("Lidarr import execution track is duplicated")
		}
		seenArtifacts[track.ArtifactID] = struct{}{}
		seenTracks[track.TrackID] = struct{}{}
	}
	switch record.State {
	case ImportPrepared:
		if record.CommandID != nil || len(record.Confirmations) != 0 {
			return fmt.Errorf("prepared Lidarr import contains later state")
		}
	case ImportRequested, ImportFailed:
		if record.CommandID == nil || *record.CommandID <= 0 || len(record.Confirmations) != 0 {
			return fmt.Errorf("requested Lidarr import state is incomplete")
		}
	case Imported:
		if err := validateConfirmations(record, record.Confirmations); err != nil {
			return err
		}
	default:
		return fmt.Errorf("Lidarr import execution state %q is invalid", record.State)
	}
	return nil
}

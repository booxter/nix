package casestore

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
)

const ManualImportExecutionVersionV1 = "radarr-repair-manual-import/v1"

type ManualImportExecutionState string

const (
	ManualImportPrepared  ManualImportExecutionState = "manual_import_prepared"
	ManualImportRequested ManualImportExecutionState = "manual_import_requested"
	ManualImportImported  ManualImportExecutionState = "imported"
	ManualImportFailed    ManualImportExecutionState = "import_failed"
)

type ManualImportExecution struct {
	Version             string                     `json:"version"`
	CaseID              string                     `json:"case_id"`
	CapabilityID        string                     `json:"capability_id"`
	FileID              controller.FileID          `json:"file_id"`
	ExpectedFingerprint controller.FileFingerprint `json:"expected_fingerprint"`
	State               ManualImportExecutionState `json:"state"`
	PreparedAt          time.Time                  `json:"prepared_at"`
	UpdatedAt           time.Time                  `json:"updated_at"`
	CommandID           *int64                     `json:"command_id,omitempty"`
	Confirmation        *ManualImportConfirmation  `json:"confirmation,omitempty"`
}

type ManualImportConfirmation struct {
	HistoryID    int64     `json:"history_id"`
	MovieFileID  int64     `json:"movie_file_id"`
	MovieID      int64     `json:"movie_id"`
	DownloadID   string    `json:"download_id"`
	OccurredAt   time.Time `json:"occurred_at"`
	DroppedPath  string    `json:"dropped_path"`
	ImportedPath string    `json:"imported_path"`
}

func EncodeManualImportExecution(record ManualImportExecution) ([]byte, error) {
	if err := validateManualImportExecution(record); err != nil {
		return nil, err
	}
	data, err := json.Marshal(record)
	if err != nil {
		return nil, fmt.Errorf("encode manual import execution: %w", err)
	}
	return data, nil
}

func DecodeManualImportExecution(data []byte) (ManualImportExecution, error) {
	var record ManualImportExecution
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return ManualImportExecution{}, fmt.Errorf("decode manual import execution: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return ManualImportExecution{}, fmt.Errorf(
				"decode manual import execution: multiple JSON values",
			)
		}
		return ManualImportExecution{}, fmt.Errorf(
			"decode manual import execution trailing JSON: %w",
			err,
		)
	}
	if err := validateManualImportExecution(record); err != nil {
		return ManualImportExecution{}, err
	}
	return record, nil
}

func (store *Store) GetManualImportExecution(
	caseID string,
) (ManualImportExecution, bool, error) {
	path, err := store.executionPath(caseID)
	if err != nil {
		return ManualImportExecution{}, false, err
	}
	record, found, err := readManualImportExecution(path)
	if err != nil {
		return ManualImportExecution{}, false, err
	}
	if found && record.CaseID != caseID {
		return ManualImportExecution{}, false, fmt.Errorf(
			"stored execution has unexpected case ID %q",
			record.CaseID,
		)
	}
	return record, found, nil
}

func (store *Store) PrepareManualImport(
	authorized decisionpolicy.AuthorizedManualImport,
	preparedAt time.Time,
) (ManualImportExecution, bool, error) {
	if preparedAt.IsZero() {
		return ManualImportExecution{}, false, fmt.Errorf("manual import preparation time is required")
	}
	path, err := store.executionPath(authorized.CaseID)
	if err != nil {
		return ManualImportExecution{}, false, err
	}

	lock, err := store.lock()
	if err != nil {
		return ManualImportExecution{}, false, err
	}
	defer unlock(lock)

	if err := store.validateManualImportAuthorization(authorized); err != nil {
		return ManualImportExecution{}, false, err
	}
	previous, found, err := readManualImportExecution(path)
	if err != nil {
		return ManualImportExecution{}, false, err
	}
	if found {
		if sameManualImport(previous, authorized) {
			return previous, false, nil
		}
		return ManualImportExecution{}, false, fmt.Errorf(
			"case %q is already bound to a different manual import",
			authorized.CaseID,
		)
	}

	record := ManualImportExecution{
		Version:             ManualImportExecutionVersionV1,
		CaseID:              authorized.CaseID,
		CapabilityID:        authorized.CapabilityID,
		FileID:              authorized.FileID,
		ExpectedFingerprint: authorized.ExpectedFingerprint,
		State:               ManualImportPrepared,
		PreparedAt:          preparedAt.UTC(),
		UpdatedAt:           preparedAt.UTC(),
	}
	if err := store.writeManualImportExecution(path, record); err != nil {
		return ManualImportExecution{}, false, err
	}
	return record, true, nil
}

func (store *Store) MarkManualImportRequested(
	caseID string,
	commandID int64,
	updatedAt time.Time,
) (ManualImportExecution, bool, error) {
	if commandID <= 0 {
		return ManualImportExecution{}, false, fmt.Errorf("Radarr command ID must be positive")
	}
	return store.updateManualImportExecution(
		caseID,
		updatedAt,
		func(previous ManualImportExecution) (ManualImportExecution, bool, error) {
			switch previous.State {
			case ManualImportPrepared:
				previous.State = ManualImportRequested
				previous.CommandID = int64Pointer(commandID)
				return previous, true, nil
			case ManualImportRequested:
				if previous.CommandID != nil && *previous.CommandID == commandID {
					return previous, false, nil
				}
				return ManualImportExecution{}, false, fmt.Errorf(
					"manual import is already bound to a different Radarr command",
				)
			default:
				return ManualImportExecution{}, false, fmt.Errorf(
					"cannot request manual import from state %q",
					previous.State,
				)
			}
		},
	)
}

func (store *Store) MarkManualImportImported(
	authorized decisionpolicy.AuthorizedManualImport,
	imported controller.RadarrImportedFile,
	updatedAt time.Time,
) (ManualImportExecution, bool, error) {
	if err := store.validateManualImportAuthorization(authorized); err != nil {
		return ManualImportExecution{}, false, err
	}
	if imported.MovieID != authorized.File.MovieID ||
		imported.DownloadID != authorized.File.DownloadID ||
		imported.DroppedPath != authorized.File.Path {
		return ManualImportExecution{}, false, fmt.Errorf(
			"Radarr import confirmation does not match the authorized file",
		)
	}
	confirmation := manualImportConfirmation(imported)
	if err := validateManualImportConfirmation(confirmation); err != nil {
		return ManualImportExecution{}, false, err
	}
	return store.updateManualImportExecution(
		authorized.CaseID,
		updatedAt,
		func(previous ManualImportExecution) (ManualImportExecution, bool, error) {
			if !sameManualImport(previous, authorized) {
				return ManualImportExecution{}, false, fmt.Errorf(
					"manual import confirmation does not match the prepared operation",
				)
			}
			switch previous.State {
			case ManualImportPrepared, ManualImportRequested:
				if !confirmation.OccurredAt.After(previous.PreparedAt) {
					return ManualImportExecution{}, false, fmt.Errorf(
						"Radarr import confirmation does not follow preparation",
					)
				}
				previous.State = ManualImportImported
				previous.Confirmation = &confirmation
				return previous, true, nil
			case ManualImportImported:
				if previous.Confirmation != nil && *previous.Confirmation == confirmation {
					return previous, false, nil
				}
				return ManualImportExecution{}, false, fmt.Errorf(
					"manual import is already bound to different confirmation evidence",
				)
			default:
				return ManualImportExecution{}, false, fmt.Errorf(
					"cannot mark manual import %q from state %q",
					ManualImportImported,
					previous.State,
				)
			}
		},
	)
}

func (store *Store) MarkManualImportFailed(
	caseID string,
	updatedAt time.Time,
) (ManualImportExecution, bool, error) {
	return store.updateManualImportExecution(
		caseID,
		updatedAt,
		func(previous ManualImportExecution) (ManualImportExecution, bool, error) {
			switch previous.State {
			case ManualImportPrepared, ManualImportRequested:
				previous.State = ManualImportFailed
				return previous, true, nil
			case ManualImportFailed:
				return previous, false, nil
			default:
				return ManualImportExecution{}, false, fmt.Errorf(
					"cannot mark manual import %q from state %q",
					ManualImportFailed,
					previous.State,
				)
			}
		},
	)
}

func (store *Store) updateManualImportExecution(
	caseID string,
	updatedAt time.Time,
	update func(ManualImportExecution) (ManualImportExecution, bool, error),
) (ManualImportExecution, bool, error) {
	if updatedAt.IsZero() {
		return ManualImportExecution{}, false, fmt.Errorf("manual import update time is required")
	}
	path, err := store.executionPath(caseID)
	if err != nil {
		return ManualImportExecution{}, false, err
	}
	lock, err := store.lock()
	if err != nil {
		return ManualImportExecution{}, false, err
	}
	defer unlock(lock)

	previous, found, err := readManualImportExecution(path)
	if err != nil {
		return ManualImportExecution{}, false, err
	}
	if !found {
		return ManualImportExecution{}, false, fmt.Errorf(
			"manual import for case %q is not prepared",
			caseID,
		)
	}
	if previous.CaseID != caseID {
		return ManualImportExecution{}, false, fmt.Errorf(
			"stored execution has unexpected case ID %q",
			previous.CaseID,
		)
	}
	if updatedAt.Before(previous.UpdatedAt) {
		return ManualImportExecution{}, false, fmt.Errorf("manual import update time moved backwards")
	}
	record, changed, err := update(previous)
	if err != nil || !changed {
		return record, changed, err
	}
	record.UpdatedAt = updatedAt.UTC()
	if err := store.writeManualImportExecution(path, record); err != nil {
		return ManualImportExecution{}, false, err
	}
	return record, true, nil
}

func (store *Store) validateManualImportAuthorization(
	authorized decisionpolicy.AuthorizedManualImport,
) error {
	assembly, decision, err := store.storedAssemblyAndDecision(authorized.CaseID)
	if err != nil {
		return err
	}
	validation := decisionpolicy.ValidateManualImport(assembly, decision)
	if !validation.Accepted() || validation.Authorized == nil ||
		!reflect.DeepEqual(*validation.Authorized, authorized) {
		return fmt.Errorf("manual import authorization does not match stored case and decision")
	}
	return nil
}

func (store *Store) storedAssemblyAndDecision(
	caseID string,
) (casebuilder.Assembly, contracts.RepairDecisionV1, error) {
	casePath, err := store.recordPath(caseID)
	if err != nil {
		return casebuilder.Assembly{}, contracts.RepairDecisionV1{}, err
	}
	caseRecord, found, err := readRecord(casePath)
	if err != nil {
		return casebuilder.Assembly{}, contracts.RepairDecisionV1{}, err
	}
	if !found {
		return casebuilder.Assembly{}, contracts.RepairDecisionV1{}, fmt.Errorf(
			"case %q is not stored",
			caseID,
		)
	}
	if caseRecord.CaseID != caseID {
		return casebuilder.Assembly{}, contracts.RepairDecisionV1{}, fmt.Errorf(
			"stored record has unexpected case ID %q",
			caseRecord.CaseID,
		)
	}
	planningPath, err := store.planningResultPath(caseID)
	if err != nil {
		return casebuilder.Assembly{}, contracts.RepairDecisionV1{}, err
	}
	planning, found, err := readPlanningResult(planningPath)
	if err != nil {
		return casebuilder.Assembly{}, contracts.RepairDecisionV1{}, err
	}
	if !found || !planning.HasDecision() {
		return casebuilder.Assembly{}, contracts.RepairDecisionV1{}, fmt.Errorf(
			"case %q has no stored planning decision",
			caseID,
		)
	}
	if planning.CaseID != caseID {
		return casebuilder.Assembly{}, contracts.RepairDecisionV1{}, fmt.Errorf(
			"stored planning result has unexpected case ID %q",
			planning.CaseID,
		)
	}
	decision, err := contracts.DecodeDecision(planning.Decision)
	if err != nil {
		return casebuilder.Assembly{}, contracts.RepairDecisionV1{}, fmt.Errorf(
			"decode stored planning decision: %w",
			err,
		)
	}
	request, err := contracts.DecodeCase(caseRecord.Request)
	if err != nil {
		return casebuilder.Assembly{}, contracts.RepairDecisionV1{}, fmt.Errorf(
			"decode stored repair case: %w",
			err,
		)
	}
	return casebuilder.Assembly{
		Request: request, EncodedRequest: cloneBytes(caseRecord.Request),
		LocalSnapshot: caseRecord.Snapshot,
	}, decision, nil
}

func (store *Store) executionPath(caseID string) (string, error) {
	digest, err := caseDigest(caseID)
	if err != nil {
		return "", err
	}
	return filepath.Join(store.executionDir, digest+".json"), nil
}

func (store *Store) writeManualImportExecution(
	path string,
	record ManualImportExecution,
) error {
	data, err := EncodeManualImportExecution(record)
	if err != nil {
		return err
	}
	return replacePrivateFile(store.executionDir, path, data)
}

func readManualImportExecution(path string) (ManualImportExecution, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return ManualImportExecution{}, false, nil
	}
	if err != nil {
		return ManualImportExecution{}, false, fmt.Errorf("read manual import execution: %w", err)
	}
	record, err := DecodeManualImportExecution(data)
	if err != nil {
		return ManualImportExecution{}, true, fmt.Errorf(
			"validate stored manual import execution: %w",
			err,
		)
	}
	return record, true, nil
}

func validateManualImportExecution(record ManualImportExecution) error {
	if record.Version != ManualImportExecutionVersionV1 {
		return fmt.Errorf("unsupported manual import execution version %q", record.Version)
	}
	if _, err := caseDigest(record.CaseID); err != nil {
		return err
	}
	if record.CapabilityID == "" || record.FileID == "" ||
		record.ExpectedFingerprint.SizeBytes <= 0 {
		return fmt.Errorf("manual import execution identity is incomplete")
	}
	if record.PreparedAt.IsZero() || record.UpdatedAt.IsZero() ||
		record.UpdatedAt.Before(record.PreparedAt) {
		return fmt.Errorf("manual import execution times are invalid")
	}
	switch record.State {
	case ManualImportPrepared:
		if record.CommandID != nil || record.Confirmation != nil {
			return fmt.Errorf("prepared manual import has result evidence")
		}
	case ManualImportRequested:
		if record.CommandID == nil || *record.CommandID <= 0 {
			return fmt.Errorf("requested manual import requires a Radarr command ID")
		}
		if record.Confirmation != nil {
			return fmt.Errorf("requested manual import has confirmation evidence")
		}
	case ManualImportImported:
		if record.CommandID != nil && *record.CommandID <= 0 {
			return fmt.Errorf("manual import Radarr command ID must be positive")
		}
		if record.Confirmation == nil {
			return fmt.Errorf("imported manual import requires confirmation evidence")
		}
		if err := validateManualImportConfirmation(*record.Confirmation); err != nil {
			return err
		}
		if !record.Confirmation.OccurredAt.After(record.PreparedAt) {
			return fmt.Errorf("Radarr import confirmation does not follow preparation")
		}
	case ManualImportFailed:
		if record.CommandID != nil && *record.CommandID <= 0 {
			return fmt.Errorf("manual import Radarr command ID must be positive")
		}
		if record.Confirmation != nil {
			return fmt.Errorf("failed manual import has confirmation evidence")
		}
	default:
		return fmt.Errorf("unknown manual import execution state %q", record.State)
	}
	return nil
}

func sameManualImport(
	record ManualImportExecution,
	authorized decisionpolicy.AuthorizedManualImport,
) bool {
	return record.CaseID == authorized.CaseID &&
		record.CapabilityID == authorized.CapabilityID &&
		record.FileID == authorized.FileID &&
		record.ExpectedFingerprint == authorized.ExpectedFingerprint
}

func int64Pointer(value int64) *int64 {
	return &value
}

func manualImportConfirmation(imported controller.RadarrImportedFile) ManualImportConfirmation {
	return ManualImportConfirmation{
		HistoryID: imported.HistoryID, MovieFileID: imported.MovieFileID,
		MovieID: imported.MovieID, DownloadID: imported.DownloadID,
		OccurredAt: imported.OccurredAt.UTC(), DroppedPath: imported.DroppedPath,
		ImportedPath: imported.ImportedPath,
	}
}

func validateManualImportConfirmation(confirmation ManualImportConfirmation) error {
	if confirmation.HistoryID <= 0 || confirmation.MovieFileID <= 0 || confirmation.MovieID <= 0 {
		return fmt.Errorf("Radarr import confirmation IDs must be positive")
	}
	if confirmation.DownloadID == "" ||
		strings.TrimSpace(confirmation.DownloadID) != confirmation.DownloadID ||
		strings.ContainsRune(confirmation.DownloadID, '\x00') {
		return fmt.Errorf("Radarr import confirmation download ID is invalid")
	}
	if confirmation.OccurredAt.IsZero() {
		return fmt.Errorf("Radarr import confirmation time is missing")
	}
	if !validExecutionPath(confirmation.DroppedPath) ||
		!validExecutionPath(confirmation.ImportedPath) {
		return fmt.Errorf("Radarr import confirmation paths are invalid")
	}
	return nil
}

func validExecutionPath(path string) bool {
	return path != "" && !strings.ContainsRune(path, '\x00') &&
		filepath.IsAbs(path) && filepath.Clean(path) == path && filepath.Dir(path) != path
}

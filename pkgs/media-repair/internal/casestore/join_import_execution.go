package casestore

import (
	"fmt"
	"reflect"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

type JoinImportRequest struct {
	Command         controller.RadarrManualImportCommand
	HistoryIDBefore int64
}

type JoinImport struct {
	Command controller.RadarrManualImportCommand `json:"command"`
	// HistoryIDBefore separates this request from older matching imports.
	HistoryIDBefore int64     `json:"history_id_before"`
	PreparedAt      time.Time `json:"prepared_at"`
	CommandID       *int64    `json:"command_id,omitempty"`
}

func (store *Store) PrepareJoinImport(
	caseID string,
	request JoinImportRequest,
	preparedAt time.Time,
) (JoinExecution, bool, error) {
	if err := store.validateJoinImportRequest(caseID, request); err != nil {
		return JoinExecution{}, false, err
	}
	return store.updateJoinExecution(
		caseID,
		preparedAt,
		func(previous JoinExecution) (JoinExecution, bool, error) {
			if previous.Import != nil {
				if sameJoinImportRequest(*previous.Import, request) {
					return previous, false, nil
				}
				return JoinExecution{}, false, fmt.Errorf(
					"join is already bound to a different Radarr import",
				)
			}
			if previous.State != JoinPublished {
				return JoinExecution{}, false, fmt.Errorf(
					"cannot prepare Radarr import from state %q",
					previous.State,
				)
			}
			previous.State = JoinImportPrepared
			previous.Import = &JoinImport{
				Command: request.Command, HistoryIDBefore: request.HistoryIDBefore,
				PreparedAt: preparedAt.UTC(),
			}
			return previous, true, nil
		},
	)
}

func (store *Store) MarkJoinImportRequested(
	caseID string,
	commandID int64,
	updatedAt time.Time,
) (JoinExecution, bool, error) {
	if commandID <= 0 {
		return JoinExecution{}, false, fmt.Errorf("Radarr command ID must be positive")
	}
	return store.updateJoinExecution(
		caseID,
		updatedAt,
		func(previous JoinExecution) (JoinExecution, bool, error) {
			switch previous.State {
			case JoinImportPrepared:
				if previous.Import == nil {
					return JoinExecution{}, false, fmt.Errorf("prepared Radarr import is missing")
				}
				previous.State = JoinImportRequested
				previous.Import.CommandID = int64Pointer(commandID)
				return previous, true, nil
			case JoinImportRequested:
				if previous.Import != nil && previous.Import.CommandID != nil &&
					*previous.Import.CommandID == commandID {
					return previous, false, nil
				}
				return JoinExecution{}, false, fmt.Errorf(
					"Radarr import is already bound to a different command",
				)
			default:
				return JoinExecution{}, false, fmt.Errorf(
					"cannot request Radarr import from state %q",
					previous.State,
				)
			}
		},
	)
}

func (store *Store) MarkJoinImported(
	caseID string,
	imported controller.RadarrImportedFile,
	updatedAt time.Time,
) (JoinExecution, bool, error) {
	confirmation := radarrImportConfirmation(imported)
	if err := validateRadarrImportConfirmation(confirmation); err != nil {
		return JoinExecution{}, false, err
	}
	return store.updateJoinExecution(
		caseID,
		updatedAt,
		func(previous JoinExecution) (JoinExecution, bool, error) {
			if previous.Import == nil ||
				imported.MovieID != previous.Import.Command.File.MovieID ||
				imported.DownloadID != previous.Import.Command.File.DownloadID ||
				imported.DroppedPath != previous.Import.Command.File.Path {
				return JoinExecution{}, false, fmt.Errorf(
					"Radarr import confirmation does not match the joined file",
				)
			}
			switch previous.State {
			case JoinImportPrepared, JoinImportRequested:
				if confirmation.HistoryID <= previous.Import.HistoryIDBefore {
					return JoinExecution{}, false, fmt.Errorf(
						"Radarr import confirmation predates the request",
					)
				}
				previous.State = JoinImported
				previous.Confirmation = &confirmation
				return previous, true, nil
			case JoinImported:
				if previous.Confirmation != nil && *previous.Confirmation == confirmation {
					return previous, false, nil
				}
				return JoinExecution{}, false, fmt.Errorf(
					"joined file is already bound to different import evidence",
				)
			default:
				return JoinExecution{}, false, fmt.Errorf(
					"cannot mark joined file imported from state %q",
					previous.State,
				)
			}
		},
	)
}

func (store *Store) MarkJoinImportFailed(
	caseID string,
	updatedAt time.Time,
) (JoinExecution, bool, error) {
	return store.updateJoinExecution(
		caseID,
		updatedAt,
		func(previous JoinExecution) (JoinExecution, bool, error) {
			switch previous.State {
			case JoinImportRequested:
				previous.State = JoinImportFailed
				return previous, true, nil
			case JoinImportFailed:
				return previous, false, nil
			default:
				return JoinExecution{}, false, fmt.Errorf(
					"cannot mark joined-file import failed from state %q",
					previous.State,
				)
			}
		},
	)
}

func (store *Store) validateJoinImportRequest(caseID string, request JoinImportRequest) error {
	if !request.Command.Complete() || request.HistoryIDBefore < 0 {
		return fmt.Errorf("Radarr import request is invalid")
	}
	planned, err := store.GetPlannedCase(caseID)
	if err != nil {
		return err
	}
	assembly := planned.Assembly
	observation := assembly.LocalSnapshot.Observation
	if observation.Movie == nil || observation.Correlation.Radarr.MovieID == nil ||
		observation.Movie.ID != *observation.Correlation.Radarr.MovieID {
		return fmt.Errorf("Radarr import does not match the stored case")
	}
	expected, complete := controller.BuildRadarrPublishedFileImport(
		request.Command.File.Path,
		observation.Movie.ID,
		observation.Correlation.Radarr.DownloadID,
		observation.History,
	)
	if !complete || !reflect.DeepEqual(request.Command, expected) {
		return fmt.Errorf("Radarr import does not match the stored case")
	}
	return nil
}

func requireJoinImport(
	record JoinExecution,
	commandRequired bool,
	confirmationRequired bool,
) error {
	if err := requireJoinArtifact(record, false, true); err != nil {
		return err
	}
	if record.Import == nil {
		return fmt.Errorf("joined-file import lacks its Radarr request")
	}
	if err := validateStoredJoinImport(*record.Import, record.PreparedAt, record.UpdatedAt); err != nil {
		return err
	}
	if commandRequired && record.Import.CommandID == nil {
		return fmt.Errorf("joined-file import requires a Radarr command ID")
	}
	if record.State == JoinImportPrepared && record.Import.CommandID != nil {
		return fmt.Errorf("prepared Radarr import contains a command ID")
	}
	if confirmationRequired {
		if record.Confirmation == nil {
			return fmt.Errorf("joined-file import lacks confirmation evidence")
		}
		if err := validateRadarrImportConfirmation(*record.Confirmation); err != nil {
			return err
		}
		if record.Confirmation.MovieID != record.Import.Command.File.MovieID ||
			record.Confirmation.DownloadID != record.Import.Command.File.DownloadID ||
			record.Confirmation.DroppedPath != record.Import.Command.File.Path ||
			record.Confirmation.HistoryID <= record.Import.HistoryIDBefore {
			return fmt.Errorf("Radarr import confirmation does not match the joined file")
		}
	} else if record.Confirmation != nil {
		return fmt.Errorf("unconfirmed joined-file import contains confirmation evidence")
	}
	return nil
}

func validateStoredJoinImport(record JoinImport, executionPreparedAt, updatedAt time.Time) error {
	if !record.Command.Complete() || record.HistoryIDBefore < 0 || record.PreparedAt.IsZero() ||
		record.PreparedAt.Before(executionPreparedAt) || record.PreparedAt.After(updatedAt) ||
		(record.CommandID != nil && *record.CommandID <= 0) {
		return fmt.Errorf("stored Radarr import is invalid")
	}
	return nil
}

func sameJoinImportRequest(record JoinImport, request JoinImportRequest) bool {
	return reflect.DeepEqual(record.Command, request.Command)
}

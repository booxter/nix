package casestore

import (
	"fmt"
	"strings"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

type JoinScanRequest struct {
	Path       string
	MovieID    int64
	DownloadID string
}

type JoinScan struct {
	Path       string    `json:"path"`
	MovieID    int64     `json:"movie_id"`
	DownloadID string    `json:"download_id"`
	PreparedAt time.Time `json:"prepared_at"`
	CommandID  *int64    `json:"command_id,omitempty"`
}

func (store *Store) PrepareJoinScan(
	caseID string,
	request JoinScanRequest,
	preparedAt time.Time,
) (JoinExecution, bool, error) {
	if err := store.validateJoinScanRequest(caseID, request); err != nil {
		return JoinExecution{}, false, err
	}
	return store.updateJoinExecution(
		caseID,
		preparedAt,
		func(previous JoinExecution) (JoinExecution, bool, error) {
			if previous.Scan != nil {
				if sameJoinScanRequest(*previous.Scan, request) {
					return previous, false, nil
				}
				return JoinExecution{}, false, fmt.Errorf(
					"join is already bound to a different Radarr scan",
				)
			}
			if previous.State != JoinPublished {
				return JoinExecution{}, false, fmt.Errorf(
					"cannot prepare Radarr scan from state %q",
					previous.State,
				)
			}
			previous.State = JoinScanPrepared
			previous.Scan = &JoinScan{
				Path: request.Path, MovieID: request.MovieID,
				DownloadID: request.DownloadID, PreparedAt: preparedAt.UTC(),
			}
			return previous, true, nil
		},
	)
}

func (store *Store) MarkJoinScanRequested(
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
			case JoinScanPrepared:
				if previous.Scan == nil {
					return JoinExecution{}, false, fmt.Errorf("prepared Radarr scan is missing")
				}
				previous.State = JoinScanRequested
				previous.Scan.CommandID = int64Pointer(commandID)
				return previous, true, nil
			case JoinScanRequested:
				if previous.Scan != nil && previous.Scan.CommandID != nil &&
					*previous.Scan.CommandID == commandID {
					return previous, false, nil
				}
				return JoinExecution{}, false, fmt.Errorf(
					"Radarr scan is already bound to a different command",
				)
			default:
				return JoinExecution{}, false, fmt.Errorf(
					"cannot request Radarr scan from state %q",
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
			if previous.Scan == nil || imported.MovieID != previous.Scan.MovieID ||
				imported.DownloadID != previous.Scan.DownloadID ||
				imported.DroppedPath != previous.Scan.Path {
				return JoinExecution{}, false, fmt.Errorf(
					"Radarr import confirmation does not match the joined file",
				)
			}
			switch previous.State {
			case JoinScanPrepared, JoinScanRequested:
				if !confirmation.OccurredAt.After(previous.Scan.PreparedAt) {
					return JoinExecution{}, false, fmt.Errorf(
						"Radarr import confirmation does not follow scan preparation",
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
			case JoinScanRequested:
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

func (store *Store) validateJoinScanRequest(caseID string, request JoinScanRequest) error {
	if !validExecutionPath(request.Path) || request.MovieID <= 0 ||
		request.DownloadID == "" || strings.TrimSpace(request.DownloadID) != request.DownloadID ||
		strings.ContainsRune(request.DownloadID, '\x00') {
		return fmt.Errorf("Radarr scan request is invalid")
	}
	assembly, _, err := store.storedAssemblyAndDecision(caseID)
	if err != nil {
		return err
	}
	observation := assembly.LocalSnapshot.Observation
	if observation.Movie == nil || observation.Correlation.Radarr.MovieID == nil ||
		request.MovieID != observation.Movie.ID ||
		request.MovieID != *observation.Correlation.Radarr.MovieID ||
		request.DownloadID != observation.Correlation.Radarr.DownloadID {
		return fmt.Errorf("Radarr scan does not match the stored case")
	}
	return nil
}

func requireJoinScan(
	record JoinExecution,
	commandRequired bool,
	confirmationRequired bool,
) error {
	if err := requireJoinArtifact(record, false, true); err != nil {
		return err
	}
	if record.Scan == nil {
		return fmt.Errorf("joined-file import lacks its Radarr scan")
	}
	if err := validateStoredJoinScan(*record.Scan, record.PreparedAt, record.UpdatedAt); err != nil {
		return err
	}
	if commandRequired && record.Scan.CommandID == nil {
		return fmt.Errorf("joined-file import requires a Radarr command ID")
	}
	if record.State == JoinScanPrepared && record.Scan.CommandID != nil {
		return fmt.Errorf("prepared Radarr scan contains a command ID")
	}
	if confirmationRequired {
		if record.Confirmation == nil {
			return fmt.Errorf("joined-file import lacks confirmation evidence")
		}
		if err := validateRadarrImportConfirmation(*record.Confirmation); err != nil {
			return err
		}
		if record.Confirmation.MovieID != record.Scan.MovieID ||
			record.Confirmation.DownloadID != record.Scan.DownloadID ||
			record.Confirmation.DroppedPath != record.Scan.Path ||
			!record.Confirmation.OccurredAt.After(record.Scan.PreparedAt) {
			return fmt.Errorf("Radarr import confirmation does not match the joined file")
		}
	} else if record.Confirmation != nil {
		return fmt.Errorf("unconfirmed joined-file import contains confirmation evidence")
	}
	return nil
}

func validateStoredJoinScan(scan JoinScan, executionPreparedAt, updatedAt time.Time) error {
	if !validExecutionPath(scan.Path) || scan.MovieID <= 0 ||
		scan.DownloadID == "" || strings.TrimSpace(scan.DownloadID) != scan.DownloadID ||
		strings.ContainsRune(scan.DownloadID, '\x00') || scan.PreparedAt.IsZero() ||
		scan.PreparedAt.Before(executionPreparedAt) || scan.PreparedAt.After(updatedAt) ||
		(scan.CommandID != nil && *scan.CommandID <= 0) {
		return fmt.Errorf("stored Radarr scan is invalid")
	}
	return nil
}

func sameJoinScanRequest(scan JoinScan, request JoinScanRequest) bool {
	return scan.Path == request.Path && scan.MovieID == request.MovieID &&
		scan.DownloadID == request.DownloadID
}

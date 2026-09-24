package casestore

import (
	"fmt"
	"reflect"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

func (store *Store) PrepareRemuxImport(
	caseID string,
	request JoinImportRequest,
	preparedAt time.Time,
) (RemuxExecution, bool, error) {
	if err := store.validateJoinImportRequest(caseID, request); err != nil {
		return RemuxExecution{}, false, err
	}
	return store.updateRemuxExecution(caseID, preparedAt, func(previous RemuxExecution) (RemuxExecution, bool, error) {
		if previous.Import != nil {
			if reflect.DeepEqual(previous.Import.Command, request.Command) &&
				previous.Import.HistoryIDBefore == request.HistoryIDBefore {
				return previous, false, nil
			}
			return RemuxExecution{}, false, fmt.Errorf("remux is bound to a different Radarr import")
		}
		if previous.State != RemuxPublished {
			return RemuxExecution{}, false, fmt.Errorf("remux is not published")
		}
		previous.State = RemuxImportPrepared
		previous.Import = &JoinImport{
			Command: request.Command, HistoryIDBefore: request.HistoryIDBefore,
			PreparedAt: preparedAt.UTC(),
		}
		return previous, true, nil
	})
}

func (store *Store) MarkRemuxImportRequested(
	caseID string,
	commandID int64,
	updatedAt time.Time,
) (RemuxExecution, bool, error) {
	if commandID <= 0 {
		return RemuxExecution{}, false, fmt.Errorf("Radarr command ID must be positive")
	}
	return store.updateRemuxExecution(caseID, updatedAt, func(previous RemuxExecution) (RemuxExecution, bool, error) {
		switch previous.State {
		case RemuxImportPrepared:
			previous.State = RemuxImportRequested
			previous.Import.CommandID = int64Pointer(commandID)
			return previous, true, nil
		case RemuxImportRequested:
			if previous.Import != nil && previous.Import.CommandID != nil &&
				*previous.Import.CommandID == commandID {
				return previous, false, nil
			}
			return RemuxExecution{}, false, fmt.Errorf("remux import is bound to a different command")
		default:
			return RemuxExecution{}, false, fmt.Errorf("remux import is not prepared")
		}
	})
}

func (store *Store) MarkRemuxImported(
	caseID string,
	imported controller.RadarrImportedFile,
	updatedAt time.Time,
) (RemuxExecution, bool, error) {
	confirmation := radarrImportConfirmation(imported)
	if err := validateRadarrImportConfirmation(confirmation); err != nil {
		return RemuxExecution{}, false, err
	}
	return store.updateRemuxExecution(caseID, updatedAt, func(previous RemuxExecution) (RemuxExecution, bool, error) {
		if previous.Import == nil || imported.MovieID != previous.Import.Command.File.MovieID ||
			imported.DownloadID != previous.Import.Command.File.DownloadID ||
			imported.DroppedPath != previous.Import.Command.File.Path ||
			confirmation.HistoryID <= previous.Import.HistoryIDBefore {
			return RemuxExecution{}, false, fmt.Errorf("Radarr import does not confirm the remux")
		}
		switch previous.State {
		case RemuxImportPrepared, RemuxImportRequested:
			previous.State = RemuxImported
			previous.Confirmation = &confirmation
			return previous, true, nil
		case RemuxImported:
			if previous.Confirmation != nil && *previous.Confirmation == confirmation {
				return previous, false, nil
			}
			return RemuxExecution{}, false, fmt.Errorf("remux is bound to a different import")
		default:
			return RemuxExecution{}, false, fmt.Errorf("remux import is not pending")
		}
	})
}

func (store *Store) MarkRemuxImportFailed(
	caseID string,
	updatedAt time.Time,
) (RemuxExecution, bool, error) {
	return store.updateRemuxExecution(caseID, updatedAt, func(previous RemuxExecution) (RemuxExecution, bool, error) {
		switch previous.State {
		case RemuxImportRequested:
			previous.State = RemuxImportFailed
			return previous, true, nil
		case RemuxImportFailed:
			return previous, false, nil
		default:
			return RemuxExecution{}, false, fmt.Errorf("remux import is not requested")
		}
	})
}

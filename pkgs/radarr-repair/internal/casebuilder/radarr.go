package casebuilder

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

func mapRadarr(
	observation Observation,
	downloadRef string,
	inventoryFiles map[controller.FileID]controller.InventoryFile,
	paths map[controller.FileID]string,
) (contracts.Radarr, error) {
	failure := observation.Correlation.Radarr
	statusMessages := make([]contracts.StatusMessageElement, len(failure.StatusMessages))
	for index, status := range failure.StatusMessages {
		statusMessages[index] = contracts.StatusMessageElement{
			EvidenceID: opaqueID("evidence", "queue", strconv.FormatInt(failure.ID, 10), strconv.Itoa(index)),
			Title:      status.Title,
			Messages:   clone(status.Messages),
		}
	}

	history := make([]contracts.HistoryElement, len(observation.History))
	for index, event := range observation.History {
		if failure.MovieID == nil || event.MovieID != *failure.MovieID {
			return contracts.Radarr{}, fmt.Errorf("history event %d refers to another movie", event.ID)
		}
		if !strings.EqualFold(event.DownloadID, failure.DownloadID) {
			return contracts.Radarr{}, fmt.Errorf("history event %d refers to another download", event.ID)
		}
		history[index] = contracts.HistoryElement{
			EvidenceID:  opaqueID("evidence", "history", strconv.FormatInt(event.ID, 10)),
			EventType:   string(event.EventType),
			OccurredAt:  event.OccurredAt.UTC(),
			SourceTitle: event.SourceTitle,
			Quality:     qualityName(event.Quality),
			Languages:   languageNames(event.Languages),
		}
	}

	imports, err := mapManualImports(
		observation.ManualImports, inventoryFiles, paths,
	)
	if err != nil {
		return contracts.Radarr{}, err
	}
	return contracts.Radarr{
		Failure: contracts.Failure{
			QueueID:               failure.ID,
			DownloadRef:           downloadRef,
			Title:                 failure.Title,
			ErrorMessage:          failure.ErrorMessage,
			Status:                string(failure.Status),
			TrackedDownloadStatus: string(failure.TrackedDownloadStatus),
			TrackedDownloadState:  string(failure.TrackedDownloadState),
			StatusMessages:        statusMessages,
		},
		Movie:         mapMovie(observation.Movie),
		History:       history,
		ManualImports: imports,
	}, nil
}

func mapMovie(movie *controller.RadarrMovie) *contracts.MovieClass {
	if movie == nil {
		return nil
	}
	return &contracts.MovieClass{
		RadarrID:        movie.ID,
		TmdbID:          movie.TMDBID,
		ImdbID:          movie.IMDbID,
		Title:           movie.Title,
		OriginalTitle:   movie.OriginalTitle,
		AlternateTitles: clone(movie.AlternateTitles),
		Year:            int64(movie.Year),
		RuntimeMinutes:  intToInt64(movie.RuntimeMinutes),
	}
}

func mapManualImports(
	imports []controller.RadarrManualImport,
	inventoryFiles map[controller.FileID]controller.InventoryFile,
	paths map[controller.FileID]string,
) ([]contracts.ManualImportElement, error) {
	pathIDs := make(map[string]controller.FileID, len(paths))
	for fileID, path := range paths {
		if _, duplicate := pathIDs[path]; duplicate {
			return nil, fmt.Errorf("multiple inventory files use local path %q", path)
		}
		pathIDs[path] = fileID
	}
	mapped := make([]contracts.ManualImportElement, len(imports))
	seen := make(map[controller.FileID]struct{}, len(imports))
	for index, item := range imports {
		fileID, ok := pathIDs[item.Path]
		if !ok {
			return nil, fmt.Errorf("manual import path does not match the inventory")
		}
		if _, duplicate := seen[fileID]; duplicate {
			return nil, fmt.Errorf("multiple manual imports refer to file %q", fileID)
		}
		seen[fileID] = struct{}{}
		if item.SizeBytes != inventoryFiles[fileID].Fingerprint.SizeBytes {
			return nil, fmt.Errorf("manual import size does not match file %q", fileID)
		}

		rejections := make([]contracts.RejectionElement, len(item.Rejections))
		for rejectionIndex, rejection := range item.Rejections {
			rejections[rejectionIndex] = contracts.RejectionElement{
				EvidenceID: opaqueID(
					"evidence", "manual_import", string(fileID), strconv.Itoa(rejectionIndex),
				),
				Type:   mapRejectionType(rejection.Type),
				Reason: rejection.Reason,
			}
		}
		mapped[index] = contracts.ManualImportElement{
			FileID:       string(fileID),
			Quality:      qualityName(item.Quality),
			Languages:    languageNames(item.Languages),
			ReleaseGroup: optionalText(item.ReleaseGroup),
			Rejections:   rejections,
		}
	}
	return mapped, nil
}

func qualityName(quality *controller.RadarrQualityModel) *string {
	if quality == nil {
		return nil
	}
	return &quality.Quality.Name
}

func languageNames(languages []controller.RadarrLanguage) []string {
	names := make([]string, len(languages))
	for index, language := range languages {
		names[index] = language.Name
	}
	return names
}

func optionalText(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}

func mapRejectionType(value controller.RadarrManualImportRejectionType) contracts.Type {
	switch strings.ToLower(string(value)) {
	case string(contracts.Permanent):
		return contracts.Permanent
	case string(contracts.Temporary):
		return contracts.Temporary
	default:
		return contracts.TypeUnknown
	}
}

func intToInt64(value *int) *int64 {
	if value == nil {
		return nil
	}
	converted := int64(*value)
	return &converted
}

package radarr

import (
	"context"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"golift.io/starr"
	starrRadarr "golift.io/starr/radarr"
)

const manualImportPath = starrRadarr.APIver + "/manualimport"

var _ controller.RadarrManualImportReader = (*Client)(nil)

type manualImportOutput struct {
	starrRadarr.ManualImportOutput
	// Starr omits this field even though Radarr returns it and requires it in
	// the later ManualImport command.
	IndexerFlags int64                    `json:"indexerFlags"`
	Rejections   []*manualImportRejection `json:"rejections"`
}

type manualImportRejection struct {
	ReasonCode string `json:"reasonCode"`
	Reason     string `json:"reason"`
	Type       string `json:"type"`
}

func (client *Client) ReadManualImports(
	ctx context.Context,
	query controller.RadarrManualImportQuery,
) ([]controller.RadarrManualImport, error) {
	if err := validateManualImportQuery(query); err != nil {
		return nil, err
	}

	var response []*manualImportOutput
	// Starr's ManualImportContext decodes one object, but Radarr's GET endpoint
	// returns an array. Keep Starr's authenticated request path and decode that
	// array into its typed response model directly.
	err := client.api.GetInto(ctx, manualImportRequest(query), &response)
	if err != nil {
		return nil, normalizeRequestError("inspect Radarr manual imports", err)
	}
	if response == nil {
		return nil, fmt.Errorf("Radarr manual-import response is null")
	}

	imports := make([]controller.RadarrManualImport, len(response))
	seenPaths := make(map[string]struct{}, len(response))
	for index, item := range response {
		mapped, err := mapManualImport(item, query)
		if err != nil {
			return nil, fmt.Errorf("Radarr manual-import item %d: %w", index, err)
		}
		if _, exists := seenPaths[mapped.Path]; exists {
			return nil, fmt.Errorf("Radarr manual imports contain duplicate path %q", mapped.Path)
		}
		seenPaths[mapped.Path] = struct{}{}
		imports[index] = mapped
	}

	sort.Slice(imports, func(left, right int) bool {
		if imports[left].RelativePath == imports[right].RelativePath {
			return imports[left].Path < imports[right].Path
		}
		return imports[left].RelativePath < imports[right].RelativePath
	})
	return imports, nil
}

func validateManualImportQuery(query controller.RadarrManualImportQuery) error {
	if query.MovieID <= 0 {
		return fmt.Errorf("Radarr movie ID must be positive")
	}
	if query.DownloadID == "" || strings.TrimSpace(query.DownloadID) != query.DownloadID ||
		strings.ContainsRune(query.DownloadID, '\x00') {
		return fmt.Errorf("Radarr download ID is invalid")
	}
	if query.Folder == "" || strings.ContainsRune(query.Folder, '\x00') {
		return fmt.Errorf("Radarr download folder is invalid")
	}
	return nil
}

func manualImportRequest(query controller.RadarrManualImportQuery) starr.Request {
	values := make(url.Values)
	values.Set("folder", query.Folder)
	values.Set("downloadId", query.DownloadID)
	values.Set("movieId", strconv.FormatInt(query.MovieID, 10))
	// Existing-file filtering can hide hardlinked files from the observation. The
	// controller needs Radarr's decision for every video in the failed download.
	values.Set("filterExistingFiles", "false")
	return starr.Request{URI: manualImportPath, Query: values}
}

func mapManualImport(
	item *manualImportOutput,
	query controller.RadarrManualImportQuery,
) (controller.RadarrManualImport, error) {
	if item == nil {
		return controller.RadarrManualImport{}, fmt.Errorf("item is null")
	}
	if item.Path == "" || strings.ContainsRune(item.Path, '\x00') {
		return controller.RadarrManualImport{}, fmt.Errorf("path is invalid")
	}
	if item.RelativePath == "" || strings.ContainsRune(item.RelativePath, '\x00') {
		return controller.RadarrManualImport{}, fmt.Errorf("relative path is invalid")
	}
	if strings.ContainsRune(item.FolderName, '\x00') {
		return controller.RadarrManualImport{}, fmt.Errorf("folder name is invalid")
	}
	if item.Size < 0 {
		return controller.RadarrManualImport{}, fmt.Errorf("size must not be negative")
	}
	if item.Movie == nil {
		return controller.RadarrManualImport{}, fmt.Errorf("movie is missing")
	}
	if item.Movie.ID != query.MovieID {
		return controller.RadarrManualImport{}, fmt.Errorf(
			"movie ID %d does not match requested ID %d",
			item.Movie.ID,
			query.MovieID,
		)
	}
	if item.DownloadID != query.DownloadID {
		return controller.RadarrManualImport{}, fmt.Errorf("download ID does not match request")
	}

	languages, err := mapLanguages(item.Languages)
	if err != nil {
		return controller.RadarrManualImport{}, err
	}

	rejections := make([]controller.RadarrManualImportRejection, len(item.Rejections))
	for index, rejection := range item.Rejections {
		if rejection == nil {
			return controller.RadarrManualImport{}, fmt.Errorf("rejection %d is null", index)
		}
		if strings.TrimSpace(rejection.Type) == "" {
			return controller.RadarrManualImport{}, fmt.Errorf("rejection %d type is missing", index)
		}
		if rejection.ReasonCode == "" ||
			strings.TrimSpace(rejection.ReasonCode) != rejection.ReasonCode ||
			strings.ContainsRune(rejection.ReasonCode, '\x00') {
			return controller.RadarrManualImport{}, fmt.Errorf(
				"rejection %d reason code is missing or invalid", index,
			)
		}
		if strings.TrimSpace(rejection.Reason) == "" {
			return controller.RadarrManualImport{}, fmt.Errorf("rejection %d reason is missing", index)
		}
		rejections[index] = controller.RadarrManualImportRejection{
			Code:   controller.RadarrManualImportRejectionReason(rejection.ReasonCode),
			Type:   controller.RadarrManualImportRejectionType(rejection.Type),
			Reason: rejection.Reason,
		}
	}

	result := controller.RadarrManualImport{
		Path:         item.Path,
		RelativePath: item.RelativePath,
		FolderName:   item.FolderName,
		SizeBytes:    item.Size,
		MovieID:      query.MovieID,
		DownloadID:   query.DownloadID,
		Languages:    languages,
		ReleaseGroup: item.ReleaseGroup,
		IndexerFlags: item.IndexerFlags,
		Rejections:   rejections,
	}
	result.Quality = mapQuality(item.Quality)
	if item.ReleaseGroup != "" && strings.TrimSpace(item.ReleaseGroup) == "" {
		return controller.RadarrManualImport{}, fmt.Errorf("release group is blank")
	}

	return result, nil
}

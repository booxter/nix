package radarr

import (
	"context"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"golift.io/starr"
	starrRadarr "golift.io/starr/radarr"
)

const manualImportPath = starrRadarr.APIver + "/manualimport"

var _ controller.RadarrManualImportReader = (*Client)(nil)

type manualImportOutput struct {
	starrRadarr.ManualImportOutput
	// Starr omits this field even though Radarr returns it and requires it in
	// the later ManualImport command.
	IndexerFlags int64 `json:"indexerFlags"`
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

	languages := make([]controller.RadarrLanguage, len(item.Languages))
	for index, language := range item.Languages {
		if language == nil || strings.TrimSpace(language.Name) == "" {
			return controller.RadarrManualImport{}, fmt.Errorf("language %d is invalid", index)
		}
		languages[index] = controller.RadarrLanguage{ID: language.ID, Name: language.Name}
	}

	rejections := make([]controller.RadarrManualImportRejection, len(item.Rejections))
	for index, rejection := range item.Rejections {
		if rejection == nil {
			return controller.RadarrManualImport{}, fmt.Errorf("rejection %d is null", index)
		}
		if strings.TrimSpace(rejection.Type) == "" {
			return controller.RadarrManualImport{}, fmt.Errorf("rejection %d type is missing", index)
		}
		if strings.TrimSpace(rejection.Reason) == "" {
			return controller.RadarrManualImport{}, fmt.Errorf("rejection %d reason is missing", index)
		}
		rejections[index] = controller.RadarrManualImportRejection{
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
	if item.Quality != nil && item.Quality.Quality != nil &&
		strings.TrimSpace(item.Quality.Quality.Name) != "" {
		quality := item.Quality.Quality
		result.Quality = &controller.RadarrQualityModel{
			Quality: controller.RadarrQuality{
				ID: quality.ID, Name: quality.Name, Source: quality.Source,
				Resolution: quality.Resolution, Modifier: quality.Modifier,
			},
		}
		if item.Quality.Revision != nil {
			result.Quality.Revision = &controller.RadarrQualityRevision{
				Version:  item.Quality.Revision.Version,
				Real:     item.Quality.Revision.Real,
				IsRepack: item.Quality.Revision.IsRepack,
			}
		}
	}
	if item.ReleaseGroup != "" {
		if strings.TrimSpace(item.ReleaseGroup) == "" {
			return controller.RadarrManualImport{}, fmt.Errorf("release group is blank")
		}
	}

	return result, nil
}

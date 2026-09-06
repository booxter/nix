package radarr

import (
	"context"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	starrRadarr "golift.io/starr/radarr"
)

const (
	maximumMovieTextLength = 512
	maximumAlternateTitles = 1024
	maximumMovieRuntime    = 10_080
	minimumMovieYear       = 1870
	maximumMovieYear       = 3000
)

var _ controller.RadarrMovieReader = (*Client)(nil)

func (client *Client) ReadMovie(ctx context.Context, movieID int64) (controller.RadarrMovie, error) {
	if movieID <= 0 {
		return controller.RadarrMovie{}, fmt.Errorf("Radarr movie ID must be positive")
	}

	movie, err := client.api.GetMovieByIDContext(ctx, movieID)
	if err != nil {
		return controller.RadarrMovie{}, normalizeRequestError("read Radarr movie", err)
	}
	return mapMovie(movie, movieID)
}

func mapMovie(movie *starrRadarr.Movie, requestedID int64) (controller.RadarrMovie, error) {
	if movie == nil {
		return controller.RadarrMovie{}, fmt.Errorf("Radarr movie is null")
	}
	if movie.ID != requestedID {
		return controller.RadarrMovie{}, fmt.Errorf(
			"Radarr returned movie ID %d for requested ID %d",
			movie.ID,
			requestedID,
		)
	}
	if movie.TmdbID <= 0 {
		return controller.RadarrMovie{}, fmt.Errorf("Radarr movie TMDB ID must be positive")
	}
	if err := validateMovieText("title", movie.Title); err != nil {
		return controller.RadarrMovie{}, err
	}
	if movie.Year < minimumMovieYear || movie.Year > maximumMovieYear {
		return controller.RadarrMovie{}, fmt.Errorf("Radarr movie year %d is out of range", movie.Year)
	}
	if movie.ImdbID != "" && !validIMDbID(movie.ImdbID) {
		return controller.RadarrMovie{}, fmt.Errorf("Radarr movie IMDb ID is invalid")
	}
	if movie.OriginalTitle != "" {
		if err := validateMovieText("original title", movie.OriginalTitle); err != nil {
			return controller.RadarrMovie{}, err
		}
	}
	if len(movie.AlternateTitles) > maximumAlternateTitles {
		return controller.RadarrMovie{}, fmt.Errorf(
			"Radarr movie has more than %d alternate titles",
			maximumAlternateTitles,
		)
	}

	alternateTitles := make([]string, len(movie.AlternateTitles))
	seenTitles := make(map[string]struct{}, len(movie.AlternateTitles))
	for index, alternateTitle := range movie.AlternateTitles {
		if alternateTitle == nil {
			return controller.RadarrMovie{}, fmt.Errorf("Radarr alternate title %d is null", index)
		}
		if err := validateMovieText("alternate title", alternateTitle.Title); err != nil {
			return controller.RadarrMovie{}, fmt.Errorf("Radarr alternate title %d: %w", index, err)
		}
		if _, exists := seenTitles[alternateTitle.Title]; exists {
			return controller.RadarrMovie{}, fmt.Errorf(
				"Radarr movie contains duplicate alternate title %q",
				alternateTitle.Title,
			)
		}
		seenTitles[alternateTitle.Title] = struct{}{}
		alternateTitles[index] = alternateTitle.Title
	}

	result := controller.RadarrMovie{
		ID:              movie.ID,
		TMDBID:          movie.TmdbID,
		Title:           movie.Title,
		AlternateTitles: alternateTitles,
		Year:            movie.Year,
	}
	if movie.ImdbID != "" {
		imdbID := movie.ImdbID
		result.IMDbID = &imdbID
	}
	if movie.OriginalTitle != "" {
		originalTitle := movie.OriginalTitle
		result.OriginalTitle = &originalTitle
	}
	switch {
	case movie.Runtime == 0:
	case movie.Runtime < 0 || movie.Runtime > maximumMovieRuntime:
		return controller.RadarrMovie{}, fmt.Errorf(
			"Radarr movie runtime %d minutes is out of range",
			movie.Runtime,
		)
	default:
		runtimeMinutes := movie.Runtime
		result.RuntimeMinutes = &runtimeMinutes
	}

	return result, nil
}

func validateMovieText(field, value string) error {
	if strings.TrimSpace(value) == "" {
		return fmt.Errorf("Radarr movie %s must not be blank", field)
	}
	if utf8.RuneCountInString(value) > maximumMovieTextLength {
		return fmt.Errorf("Radarr movie %s exceeds %d characters", field, maximumMovieTextLength)
	}
	for _, character := range value {
		if character <= '\x1f' || character == '\x7f' {
			return fmt.Errorf("Radarr movie %s contains a control character", field)
		}
	}
	return nil
}

func validIMDbID(value string) bool {
	if len(value) < len("tt")+7 || len(value) > len("tt")+10 || !strings.HasPrefix(value, "tt") {
		return false
	}
	for _, character := range value[len("tt"):] {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

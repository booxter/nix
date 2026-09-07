package radarr

import (
	"fmt"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"golift.io/starr"
)

func mapQuality(quality *starr.Quality) *controller.RadarrQualityModel {
	if quality == nil || quality.Quality == nil ||
		strings.TrimSpace(quality.Quality.Name) == "" {
		return nil
	}

	base := quality.Quality
	mapped := &controller.RadarrQualityModel{
		Quality: controller.RadarrQuality{
			ID: base.ID, Name: base.Name, Source: base.Source,
			Resolution: base.Resolution, Modifier: base.Modifier,
		},
	}
	if quality.Revision != nil {
		mapped.Revision = &controller.RadarrQualityRevision{
			Version:  quality.Revision.Version,
			Real:     quality.Revision.Real,
			IsRepack: quality.Revision.IsRepack,
		}
	}
	return mapped
}

func mapLanguages(languages []*starr.Value) ([]controller.RadarrLanguage, error) {
	mapped := make([]controller.RadarrLanguage, len(languages))
	for index, language := range languages {
		if language == nil || strings.TrimSpace(language.Name) == "" {
			return nil, fmt.Errorf("language %d is invalid", index)
		}
		mapped[index] = controller.RadarrLanguage{ID: language.ID, Name: language.Name}
	}
	return mapped, nil
}

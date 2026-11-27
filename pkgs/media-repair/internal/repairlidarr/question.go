package repairlidarr

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

// A release can appear in the library even when it offers no import.
// Show only editions for which this case has an import capability.
func Question(c lidarrcontracts.Case, reason string) *planning.Question {
	if len(c.Capabilities) == 0 || len(c.Releases) == 0 {
		return nil
	}
	switch reason {
	case "ambiguous_release":
		choices := releaseChoices(c)
		if len(choices) == 0 {
			return nil
		}
		return &planning.Question{
			Kind: planning.ChooseRelease, Title: "Choose a release", Text: "Which release should these tracks be imported into?",
			Hint:   "Choosing accepts uncertainty about the edition; the planner will still check the evidence.",
			Button: "Use this release", Choices: choices,
		}
	case "ambiguous_album", "ambiguous_tracks":
		question := planning.RequestGuidance("Clarify the album or tracks", "Which album or tracks should be used?")
		for _, artifact := range c.Artifacts {
			if artifact.RelativePath != "" {
				question.Context = append(question.Context, artifact.RelativePath)
			}
		}
		return question
	}
	return nil
}

func releaseChoices(c lidarrcontracts.Case) []planning.Choice {
	offered := make(map[int64]bool)
	for _, capability := range c.Capabilities {
		if capability.Action == string(lidarrcontracts.ActionImportMissingTracks) && capability.CapabilityID != "" {
			offered[capability.ReleaseID] = true
		}
	}
	var choices []planning.Choice
	for _, release := range c.Releases {
		if !offered[release.ReleaseID] || release.ReleaseID <= 0 {
			continue
		}
		label := release.Title
		for _, detail := range []string{release.Disambiguation, release.Format, strings.Join(release.Countries, ", "), strings.Join(release.Labels, ", ")} {
			if detail != "" {
				label += " — " + detail
			}
		}
		choices = append(choices, planning.Choice{
			Value: strconv.FormatInt(release.ReleaseID, 10),
			Label: fmt.Sprintf("%s (release %d)", label, release.ReleaseID),
		})
		delete(offered, release.ReleaseID)
	}
	return choices
}

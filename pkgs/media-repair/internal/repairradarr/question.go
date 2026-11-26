package repairradarr

import (
	"fmt"
	"slices"
	"strings"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/planning"
)

// Question offers only answers supported by the saved movie and its available operations.
func Question(c contracts.RepairCaseV3, reason string, missingEvidence []contracts.MissingEvidence) *planning.Question {
	if c.Radarr.Movie == nil || len(c.Capabilities) == 0 {
		return nil
	}
	var result *planning.Question
	switch reason {
	case "runtime_mismatch":
		result = planning.RequestGuidance("Runtime mismatch", "What runtime difference are you willing to accept?")
		result.Kind, result.AllowRuntime = planning.AcceptRuntime, true
	case "ambiguous_file_selection":
		result = fileQuestion(c)
	case "ambiguous_part_order":
		if !offers(c, contracts.CapabilityActionJoinParts, contracts.CapabilityActionRemuxDVD) {
			return nil
		}
		result = planning.RequestGuidance("Clarify the part order", "In what order should the parts be joined?")
	case "insufficient_evidence":
		result = missingEvidenceQuestion(c, missingEvidence)
	}
	if result == nil {
		return nil
	}
	if result.AllowRuntime && (c.Radarr.Movie.RuntimeMinutes == nil || *c.Radarr.Movie.RuntimeMinutes <= 0) {
		return nil
	}
	if c.Radarr.Movie.RuntimeMinutes != nil {
		result.Context = append(result.Context, fmt.Sprintf("Movie runtime: %d minutes", *c.Radarr.Movie.RuntimeMinutes))
	}
	for _, file := range c.Files {
		if len(file.PathComponents) == 0 {
			continue
		}
		label := strings.Join(file.PathComponents, "/")
		if file.Probe.Format != nil && file.Probe.Format.EffectiveDurationMS != nil {
			label += fmt.Sprintf(" (%d seconds)", *file.Probe.Format.EffectiveDurationMS/1000)
		}
		result.Context = append(result.Context, label)
	}
	return result
}

// Only files that Radarr can import can be offered for selection. Otherwise
// the operator may still be able to explain how several files belong together.
func fileQuestion(c contracts.RepairCaseV3) *planning.Question {
	paths := make(map[string]string)
	for _, file := range c.Files {
		if file.FileID != "" && len(file.PathComponents) > 0 {
			paths[file.FileID] = strings.Join(file.PathComponents, "/")
		}
	}
	var choices []planning.Choice
	for _, capability := range c.Capabilities {
		if capability.Action != contracts.CapabilityActionManualImportFile || capability.FileID == nil {
			continue
		}
		id := *capability.FileID
		if label, ok := paths[id]; ok {
			choices = append(choices, planning.Choice{Value: id, Label: label})
			delete(paths, id)
		}
	}
	if len(choices) < 2 {
		return planning.RequestGuidance("Clarify how to use the files", "Which files belong together, and how should they be used?")
	}
	return &planning.Question{
		Kind: planning.ChooseFile, Title: "Choose a file", Text: "Which file should be used for this movie?",
		Hint:   "Choosing accepts ambiguity; the planner will still check the evidence.",
		Button: "Use this file", Choices: choices,
	}
}

// Ask only if the operator can address every missing item with the operations
// available for this movie. Technical evidence such as a missing probe must
// come from the collector.
func missingEvidenceQuestion(c contracts.RepairCaseV3, missing []contracts.MissingEvidence) *planning.Question {
	var text string
	allowRuntime := false
	for _, item := range missing {
		switch item {
		case contracts.PartOrder, contracts.PartMembership:
			if !offers(c, contracts.CapabilityActionJoinParts, contracts.CapabilityActionRemuxDVD) {
				return nil
			}
			text = "In what order should the parts be joined?"
			if item == contracts.PartMembership {
				text = "Which files belong in the movie, and is the set complete?"
				allowRuntime = true
			}
		case contracts.DiscPlaylist:
			if !offers(c, contracts.CapabilityActionRemuxBluray, contracts.CapabilityActionRemuxDVD) {
				return nil
			}
			text = "Which disc title or playlist should be used, and is its runtime acceptable?"
			allowRuntime = true
		case contracts.MovieRuntime:
			text = "What runtime difference are you willing to accept?"
			allowRuntime = true
		case contracts.FileSelection:
			text = "Which file should be used for this movie?"
		default:
			return nil
		}
	}
	if text == "" {
		return nil
	}
	question := planning.RequestGuidance("Provide missing information", text)
	question.Hint = "Your instructions can accept ambiguity; the planner will still check the evidence."
	question.AllowRuntime = allowRuntime
	return question
}

func offers(c contracts.RepairCaseV3, actions ...contracts.CapabilityAction) bool {
	for _, capability := range c.Capabilities {
		if slices.Contains(actions, capability.Action) {
			return true
		}
	}
	return false
}

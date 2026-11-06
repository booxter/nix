package repairui

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

type attention struct {
	Kind, Title, Question, Hint, Button string
	Choices                             []attentionChoice
	Context                             []string
	AllowRuntime, RequireGuidance       bool
}

type attentionChoice struct {
	Value, Label string
}

func attentionFor(job jobs.Job, plan decision) *attention {
	if !job.InQueue || job.PendingAction != "" || job.CollectionError != "" ||
		(job.State != jobs.Blocked && job.State != jobs.Failed) {
		return nil
	}
	if strings.Contains(job.Reason, "current Lidarr evidence does not match") ||
		strings.Contains(job.Reason, "Lidarr import bindings changed") {
		return nil
	}
	var evidence struct {
		Case json.RawMessage `json:"case"`
	}
	if json.Unmarshal(job.Evidence, &evidence) != nil || len(evidence.Case) == 0 || string(evidence.Case) == "null" || string(evidence.Case) == "{}" {
		return nil
	}
	if plan.Explanation == plannerFallback {
		return &attention{Kind: "retry", Title: "Retry planning", Question: "Try planning again?", Button: "Retry planning"}
	}
	if strings.Contains(job.Reason, "repair interrupted before import") ||
		strings.Contains(job.Reason, "terminated signal received") || strings.Contains(job.Reason, "context canceled") {
		return &attention{Kind: "retry", Title: "Resume interrupted repair", Question: "Resume this interrupted repair?", Button: "Resume repair"}
	}
	if job.Reason == "decision rejected: runtime_mismatch" && job.Service == jobs.Radarr {
		return radarrAttention(evidence.Case, decision{Reason: "runtime_mismatch"})
	}
	if plan.Action != "no_repair" {
		return nil
	}
	if job.Service == jobs.Lidarr {
		return lidarrAttention(evidence.Case, plan.Reason)
	}
	if job.Service == jobs.Radarr {
		return radarrAttention(evidence.Case, plan)
	}
	return nil
}

func lidarrAttention(raw json.RawMessage, reason string) *attention {
	var c lidarrcontracts.Case
	if json.Unmarshal(raw, &c) != nil || len(c.Capabilities) == 0 || len(c.Releases) == 0 {
		return nil
	}
	switch reason {
	case "ambiguous_release":
		var choices []attentionChoice
		seen := make(map[int64]bool)
		for _, capability := range c.Capabilities {
			if capability.Action != string(lidarrcontracts.ActionImportMissingTracks) || capability.CapabilityID == "" || seen[capability.ReleaseID] {
				continue
			}
			for _, release := range c.Releases {
				if release.ReleaseID != capability.ReleaseID || release.ReleaseID <= 0 {
					continue
				}
				label := release.Title
				for _, detail := range []string{release.Disambiguation, release.Format, strings.Join(release.Countries, ", "), strings.Join(release.Labels, ", ")} {
					if detail != "" {
						label += " — " + detail
					}
				}
				choices = append(choices, attentionChoice{Value: strconv.FormatInt(release.ReleaseID, 10), Label: fmt.Sprintf("%s (release %d)", label, release.ReleaseID)})
				seen[release.ReleaseID] = true
				break
			}
		}
		if len(choices) == 0 {
			return nil
		}
		return &attention{Kind: "release", Title: "Choose a release", Question: "Which release should these tracks be imported into?", Hint: "Choosing accepts uncertainty about the edition; the planner will still check the evidence.", Button: "Use this release", Choices: choices}
	case "ambiguous_album", "ambiguous_tracks":
		result := guidanceAttention("Clarify the album or tracks", "Which album or tracks should be used?")
		for _, artifact := range c.Artifacts {
			if artifact.RelativePath != "" {
				result.Context = append(result.Context, artifact.RelativePath)
			}
		}
		return result
	}
	return nil
}

func radarrAttention(raw json.RawMessage, plan decision) *attention {
	var c contracts.RadarrRepairCaseVersion3
	if json.Unmarshal(raw, &c) != nil || c.Radarr.Movie == nil || len(c.Capabilities) == 0 {
		return nil
	}
	var result *attention
	switch plan.Reason {
	case "runtime_mismatch":
		result = guidanceAttention("Runtime mismatch", "What runtime difference are you willing to accept?")
		result.Kind, result.AllowRuntime = "runtime", true
	case "ambiguous_file_selection":
		var choices []attentionChoice
		seen := make(map[string]bool)
		for _, capability := range c.Capabilities {
			if capability.Action != contracts.PurpleManualImportFileV1 || capability.FileID == nil {
				continue
			}
			id := *capability.FileID
			for _, file := range c.Files {
				if id == "" || id != file.FileID || seen[id] || len(file.PathComponents) == 0 {
					continue
				}
				choices = append(choices, attentionChoice{Value: id, Label: strings.Join(file.PathComponents, "/")})
				seen[id] = true
			}
		}
		if len(choices) > 1 {
			result = &attention{Kind: "file", Title: "Choose a file", Question: "Which file should be used for this movie?", Hint: "Choosing accepts ambiguity; the planner will still check the evidence.", Button: "Use this file", Choices: choices}
		} else {
			result = guidanceAttention("Clarify how to use the files", "Which files belong together, and how should they be used?")
		}
	case "ambiguous_part_order":
		if !hasCapability(c, contracts.PurpleJoinPartsV1) {
			return nil
		}
		result = guidanceAttention("Clarify the part order", "In what order should the parts be joined?")
	case "insufficient_evidence":
		if len(plan.MissingEvidence) == 0 {
			return nil
		}
		allowRuntime := false
		for _, missing := range plan.MissingEvidence {
			switch missing {
			case "file_selection":
			case "part_order", "part_membership":
				if !hasCapability(c, contracts.PurpleJoinPartsV1) {
					return nil
				}
				allowRuntime = allowRuntime || missing == "part_membership"
			case "disc_playlist":
				if !hasCapability(c, contracts.PurpleRemuxBlurayV1) && !hasCapability(c, contracts.PurpleRemuxDVDV1) {
					return nil
				}
				allowRuntime = true
			case "movie_runtime":
				allowRuntime = true
			default:
				return nil
			}
		}
		question := "What information can help resolve this?"
		for _, missing := range plan.MissingEvidence {
			switch missing {
			case "part_membership":
				question = "Which files belong in the movie, and is the set complete?"
			case "part_order":
				question = "In what order should the parts be joined?"
			case "disc_playlist":
				question = "Which disc title or playlist should be used, and is its runtime acceptable?"
			case "movie_runtime":
				question = "What runtime difference are you willing to accept?"
			case "file_selection":
				question = "Which file should be used for this movie?"
			}
		}
		result = guidanceAttention("Provide missing information", question)
		result.Hint = "Your instructions can accept ambiguity; the planner will still check the evidence."
		result.AllowRuntime = allowRuntime
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

func hasCapability(c contracts.RadarrRepairCaseVersion3, action contracts.CapabilityAction) bool {
	for _, capability := range c.Capabilities {
		if capability.Action == action {
			return true
		}
	}
	return false
}

func guidanceAttention(title, question string) *attention {
	return &attention{Kind: "guidance", Title: title, Question: question, Button: "Send instructions", RequireGuidance: true}
}

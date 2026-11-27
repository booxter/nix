package repairui

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
)

const plannerFallback = "The planner could not produce a valid decision within its attempt limit."

func classifyOutcome(job jobs.Job, plan decision) jobs.Outcome {
	code := job.Outcome
	if code == "" {
		code = legacyOutcome(job, plan)
	}
	// Planning history can restore a fallback produced by an older planner.
	if code == jobs.OutcomeAlreadyReviewed && plan.Explanation == plannerFallback {
		return jobs.OutcomePlannerFailed
	}
	if plan.Reason == string(jobs.OutcomePlannerFailed) &&
		(code == "" || code == jobs.OutcomeOther || code == jobs.OutcomeAlreadyReviewed) {
		return jobs.OutcomePlannerFailed
	}
	return code
}

// Jobs written before outcome codes were introduced only have human-readable reasons.
func legacyOutcome(job jobs.Job, plan decision) jobs.Outcome {
	switch {
	case strings.Contains(job.Reason, "current Lidarr evidence does not match") || strings.Contains(job.Reason, "Lidarr import bindings changed"):
		return jobs.OutcomeEvidenceChanged
	case plan.Explanation == plannerFallback:
		return jobs.OutcomePlannerFailed
	case strings.Contains(job.Reason, "repair interrupted before import") || strings.Contains(job.Reason, "terminated signal received") || strings.Contains(job.Reason, "context canceled"):
		return jobs.OutcomeInterrupted
	case job.Reason == "decision rejected: runtime_mismatch":
		return jobs.OutcomeRuntimeMismatch
	case strings.Contains(job.Reason, "these inputs were already planned"):
		return jobs.OutcomeAlreadyReviewed
	default:
		return ""
	}
}

func present(job jobs.Job) item {
	view := item{
		review:  reviewFor(job),
		Job:     job,
		Subject: subject(job),
	}

	switch {
	case job.State == jobs.Imported || job.State == jobs.Removed || job.State == jobs.Running || job.State == jobs.Importing:
		view.Status = stateLabel(job.State)
		view.Explanation = job.Reason
	case job.PendingAction == jobs.Delete:
		view.Status = "Removal requested"
		view.Explanation = job.Reason
		view.NextStep = "Removal will be retried when possible."
	case job.PendingAction == jobs.ConfirmRemoval:
		view.Status = "Confirm removal again"
		view.Explanation = job.Reason
	case job.CollectionError != "":
		presentCollectionError(&view, job.CollectionOutcome, job.CollectionError)
		if job.PendingAction == jobs.Reconsider {
			view.NextStep += " Reconsideration will wait until this is resolved."
		}
	case job.PendingAction == jobs.Reconsider:
		view.Status = "Reconsideration queued"
		view.Explanation = job.Reason
		view.NextStep = "The planner will try again."
	case job.State != jobs.Blocked:
		view.Status = stateLabel(job.State)
		view.Explanation = job.Reason
	case view.Outcome == jobs.OutcomeEvidenceChanged:
		view.Status = "Evidence changed"
		view.Explanation = job.Reason
		view.NextStep = "Request reconsideration to review the current evidence."
	case view.Outcome == jobs.OutcomePlannerFailed:
		view.Status = "Planner failed"
		view.Explanation = "The previous planning attempt ended without a usable decision."
		view.NextStep = "Request reconsideration to try again."
	case view.Outcome == jobs.OutcomeAlreadyReviewed:
		view.Status = "Already reviewed"
		view.Explanation = job.Reason
		view.NextStep = "Request reconsideration to review these inputs again."
	case view.Decision.Action == "no_repair":
		if view.Outcome == "" || view.Outcome == jobs.OutcomeOther {
			view.Outcome = jobs.Outcome(view.Decision.Reason)
		}
		view.Status = "No automatic repair chosen"
		view.Explanation = view.Decision.Explanation
		view.NextStep = "Review the decision or request reconsideration."
	default:
		view.Status = "Blocked"
		view.Explanation = job.Reason
	}

	if view.Attention != nil {
		view.Status = view.Attention.Title
		switch view.Attention.Kind {
		case planning.AcceptRuntime:
			view.Explanation = "The proposed import exceeds the allowed runtime difference."
		case planning.Retry:
			if view.Outcome == jobs.OutcomePlannerFailed {
				view.Explanation = "The previous planning attempt ended without a usable decision."
			} else {
				view.Explanation = "The repair was interrupted before an import was submitted."
			}
		default:
			view.Explanation = view.Decision.Explanation
		}
	}
	return view
}

func subject(job jobs.Job) string {
	var evidence struct {
		Case struct {
			Album struct {
				Artist string `json:"artist"`
				Title  string `json:"title"`
			} `json:"album"`
			Radarr struct {
				Movie struct {
					Title string `json:"title"`
					Year  int    `json:"year"`
				} `json:"movie"`
			} `json:"radarr"`
		} `json:"case"`
	}
	if json.Unmarshal(job.Evidence, &evidence) == nil {
		album := evidence.Case.Album
		if album.Artist != "" && album.Title != "" {
			return album.Artist + " — " + album.Title
		}
		movie := evidence.Case.Radarr.Movie
		if movie.Title != "" && movie.Year > 0 {
			return fmt.Sprintf("%s (%d)", movie.Title, movie.Year)
		}
		if movie.Title != "" {
			return movie.Title
		}
	}
	return job.Title
}

func presentCollectionError(view *item, code jobs.Outcome, message string) {
	if code == "" {
		code = legacyCollectionOutcome(message)
	}
	view.Outcome = code
	switch code {
	case jobs.OutcomeIncompleteDownload:
		view.Status = "Waiting for download"
		view.Explanation = "Radarr still reports the download as incomplete."
		view.NextStep = "Wait for the download to finish."
	case jobs.OutcomeQueueNotReady:
		view.Status = "Queue not ready"
		view.Explanation = "The Lidarr queue entry is not eligible for repair yet."
		view.NextStep = "Wait for the queue entry to become eligible for repair."
	case jobs.OutcomeInvalidCueSheet:
		view.Status = "Files need attention"
		view.Explanation = "Repairr could not read the cue sheet to identify and split the tracks."
		view.NextStep = "Fix the cue sheet and try again."
	default:
		view.Status = "Could not inspect"
		view.Explanation = "Repairr could not inspect this download."
		view.NextStep = "Review the inspection error and try again."
	}
}

func legacyCollectionOutcome(message string) jobs.Outcome {
	switch {
	case strings.Contains(message, "incomplete_download"):
		return jobs.OutcomeIncompleteDownload
	case strings.Contains(message, "not eligible for repair"):
		return jobs.OutcomeQueueNotReady
	case strings.Contains(message, "invalid_cue_sheet"):
		return jobs.OutcomeInvalidCueSheet
	default:
		return jobs.OutcomeOther
	}
}

func stateLabel(state jobs.State) string {
	switch state {
	case jobs.Observed:
		return "Awaiting review"
	case jobs.Ready:
		return "Repair planned"
	case jobs.Running:
		return "Repairing"
	case jobs.Importing:
		return "Importing"
	case jobs.Imported:
		return "Imported"
	case jobs.Failed:
		return "Failed"
	case jobs.Blocked:
		return "Blocked"
	case jobs.Removed:
		return "Removed"
	case jobs.Removing:
		return "Removing"
	default:
		return string(state)
	}
}

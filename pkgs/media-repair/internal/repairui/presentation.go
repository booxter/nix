package repairui

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

const plannerFallback = "The planner could not produce a valid decision within its attempt limit."

func present(job jobs.Job) item {
	view := item{
		Job:     job,
		Subject: subject(job),
		CanAct:  job.InQueue && job.State != jobs.Running && job.State != jobs.Importing && job.State != jobs.Removing && job.State != jobs.Removed,
	}
	_ = json.Unmarshal(job.Plan, &view.Decision)

	switch {
	case job.State == jobs.Imported || job.State == jobs.Removed || job.State == jobs.Running || job.State == jobs.Importing:
		view.Group = "review"
		view.Status = stateLabel(job.State)
		view.Explanation = job.Reason
	case job.PendingAction == jobs.Delete:
		view.Group, view.Status = "removal", "Removal requested"
		view.Explanation = job.Reason
		view.NextStep = "Removal will be retried when possible."
	case job.CollectionError != "":
		presentCollectionError(&view, job.CollectionError)
		if job.PendingAction == jobs.Reconsider {
			view.NextStep += " Reconsideration will wait until this is resolved."
		}
	case job.PendingAction == jobs.Reconsider:
		view.Group, view.Status = "planner", "Reconsideration queued"
		view.Explanation = job.Reason
		view.NextStep = "The planner will try again."
	case job.State != jobs.Blocked:
		view.Group = "review"
		view.Status = stateLabel(job.State)
		view.Explanation = job.Reason
	case strings.Contains(job.Reason, "current Lidarr evidence does not match") || strings.Contains(job.Reason, "Lidarr import bindings changed"):
		view.Group, view.Status = "changed", "Evidence changed"
		view.Explanation = "The current Lidarr evidence no longer matches the planned repair."
		view.NextStep = "Request reconsideration to review the current evidence."
	case view.Decision.Explanation == plannerFallback:
		view.Group, view.Status = "planner", "Planner failed"
		view.Explanation = "The previous planning attempt ended without a usable decision."
		view.NextStep = "Request reconsideration to try again."
	case job.Reason == "queue entry is present again":
		view.Group, view.Status = "review", "Tracking resumed"
		view.Explanation = "The queue entry was seen again after it was removed or disappeared."
		if view.Decision.Explanation != "" && view.Decision.Explanation != plannerFallback {
			view.Explanation += " Previous decision: " + view.Decision.Explanation
		}
		view.NextStep = "Review the previous result and current queue entry before reconsidering."
	case strings.Contains(job.Reason, "these inputs were already planned"):
		view.Group, view.Status = "review", "Already reviewed"
		view.Explanation = job.Reason
		view.NextStep = "Request reconsideration to review these inputs again."
	case view.Decision.Action == "no_repair":
		view.Group, view.Status = "decision", "No automatic repair chosen"
		view.Explanation = view.Decision.Explanation
		view.NextStep = "Review the decision or request reconsideration."
	default:
		view.Group, view.Status = "review", "Blocked"
		view.Explanation = job.Reason
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

func presentCollectionError(view *item, message string) {
	switch {
	case strings.Contains(message, "incomplete_download"):
		view.Group, view.Status = "waiting", "Waiting for download"
		view.Explanation = "Radarr still reports the download as incomplete."
		view.NextStep = "Wait for the download to finish."
	case strings.Contains(message, "not eligible for repair"):
		view.Group, view.Status = "waiting", "Queue not ready"
		view.Explanation = "The Lidarr queue entry is not eligible for repair yet."
		view.NextStep = "Wait for the queue entry to become eligible for repair."
	case strings.Contains(message, "invalid_cue_sheet"):
		view.Group, view.Status = "inspection", "Files need attention"
		view.Explanation = "Repairr could not read the cue sheet to identify and split the tracks."
		view.NextStep = "Fix the cue sheet and try again."
	default:
		view.Group, view.Status = "inspection", "Could not inspect"
		view.Explanation = "Repairr could not inspect this download."
		view.NextStep = "Review the inspection error and try again."
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
	case jobs.Removed:
		return "Removed"
	case jobs.Removing:
		return "Removing"
	default:
		return string(state)
	}
}

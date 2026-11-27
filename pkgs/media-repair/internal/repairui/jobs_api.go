package repairui

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

type jobSummary struct {
	ID              int64        `json:"id"`
	Service         jobs.Service `json:"service"`
	Title           string       `json:"title"`
	Subject         string       `json:"subject"`
	State           jobs.State   `json:"state"`
	ReasonCode      jobs.Outcome `json:"reasonCode,omitempty"`
	Reason          string       `json:"reason,omitempty"`
	Findings        []string     `json:"findings,omitempty"`
	InspectionError string       `json:"inspectionError,omitempty"`
	PendingAction   string       `json:"pendingAction,omitempty"`
}

type attemptResponse struct {
	Number     int64                  `json:"number"`
	State      jobs.State             `json:"state"`
	ReasonCode jobs.Outcome           `json:"reasonCode,omitempty"`
	Reason     string                 `json:"reason,omitempty"`
	CommandID  int64                  `json:"commandId,omitempty"`
	Receipt    *servarr.ImportReceipt `json:"receipt,omitempty"`
	Question   *planning.Question     `json:"question,omitempty"`
}

type jobDetail struct {
	jobSummary
	jobResponse
	RetryAt  time.Time         `json:"retryAt,omitzero"`
	Attempts []attemptResponse `json:"attempts"`
}

// Older jobs kept the planning deadline after a successful retry. A ready
// job waiting to retry preparation still has the failure reason.
func pendingRetryAt(job jobs.Job) time.Time {
	switch job.State {
	case jobs.Observed, jobs.Ready:
		if job.InQueue && job.Reason != "" && job.InspectionProblem() == "" {
			return job.RetryAt
		}
	case jobs.Blocked:
		if job.PendingAction == jobs.Delete {
			return job.RetryAt
		}
	}
	return time.Time{}
}

func summarize(entry item) jobSummary {
	job := entry.Job
	reason := job.Reason
	// Older movie jobs saved the planner code as their reason. Use the saved
	// explanation only while that code still describes the current stop.
	plan := entry.Decision
	if plan.Action == "no_repair" && plan.Reason != "" && plan.Reason == reason && jobs.Outcome(plan.Reason) == entry.Outcome {
		reason = plan.Explanation
	}
	return jobSummary{
		ID: job.ID, Service: job.Service, Title: job.Title, Subject: entry.Subject,
		State: job.State, ReasonCode: entry.Outcome, Reason: reason,
		Findings: job.Findings, InspectionError: job.InspectionProblem(), PendingAction: job.PendingAction,
	}
}

// With no view filter, discovery includes jobs that have already left the queue.
func (app *Handler) listJobs(w http.ResponseWriter, r *http.Request) {
	filter := readListFilter(r.URL.Query())
	if err := filter.validate(); err != nil {
		jsonError(w, http.StatusBadRequest, err.Error())
		return
	}
	list, err := app.filteredJobs(r.Context(), filter)
	if err != nil {
		jsonError(w, http.StatusInternalServerError, "could not read jobs")
		return
	}
	summaries := make([]jobSummary, 0, len(list.Items))
	for _, entry := range list.Items {
		summaries = append(summaries, summarize(entry))
	}
	writeJSON(w, summaries)
}

func (app *Handler) jobInfo(w http.ResponseWriter, r *http.Request) {
	job, attempts, err := app.readDetail(r)
	if err != nil {
		status, message := jobReadError(err)
		jsonError(w, status, message)
		return
	}
	entry := present(job)
	detail := jobDetail{
		jobSummary: summarize(entry), jobResponse: app.jobActions(job, entry.review),
		RetryAt:  pendingRetryAt(job),
		Attempts: make([]attemptResponse, 0, len(attempts)),
	}
	for _, attempt := range attempts {
		detail.Attempts = append(detail.Attempts, attemptResponse{
			Number: attempt.Number, State: attempt.State,
			ReasonCode: attempt.Outcome, Reason: attempt.Reason,
			CommandID: attempt.CommandID, Receipt: attempt.ImportReceipt, Question: attempt.Question,
		})
	}
	app.setCSRFCookie(w)
	writeJSON(w, detail)
}

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

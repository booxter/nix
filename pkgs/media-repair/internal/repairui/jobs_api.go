package repairui

import (
	"encoding/json"
	"net/http"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

type jobSummary struct {
	ID              int64        `json:"id"`
	Service         jobs.Service `json:"service"`
	Title           string       `json:"title"`
	Subject         string       `json:"subject"`
	State           jobs.State   `json:"state"`
	ReasonCode      jobs.Outcome `json:"reasonCode,omitempty"`
	Reason          string       `json:"reason,omitempty"`
	InspectionError string       `json:"inspectionError,omitempty"`
	PendingAction   string       `json:"pendingAction,omitempty"`
}

type attemptResponse struct {
	Number    int64           `json:"number"`
	State     jobs.State      `json:"state"`
	Reason    string          `json:"reason,omitempty"`
	CommandID int64           `json:"commandId,omitempty"`
	Receipt   json.RawMessage `json:"receipt,omitempty"`
}

type jobDetail struct {
	jobSummary
	jobResponse
	Attempts []attemptResponse `json:"attempts"`
}

func summarize(entry item) jobSummary {
	job := entry.Job
	return jobSummary{
		ID: job.ID, Service: job.Service, Title: job.Title, Subject: entry.Subject,
		State: job.State, ReasonCode: entry.Outcome, Reason: job.Reason,
		InspectionError: job.CollectionError, PendingAction: job.PendingAction,
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
		Attempts: make([]attemptResponse, 0, len(attempts)),
	}
	for _, attempt := range attempts {
		detail.Attempts = append(detail.Attempts, attemptResponse{
			Number: attempt.Number, State: attempt.State, Reason: attempt.Reason,
			CommandID: attempt.CommandID, Receipt: attempt.ImportReceipt,
		})
	}
	app.setCSRFCookie(w)
	writeJSON(w, detail)
}

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

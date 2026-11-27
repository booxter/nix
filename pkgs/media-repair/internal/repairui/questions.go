package repairui

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strconv"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
)

type questionResponse struct {
	Question    *planning.Question `json:"question"`
	Revision    int64              `json:"revision"`
	Fingerprint string             `json:"fingerprint"`
	CSRFToken   string             `json:"csrfToken"`
}

type answerRequest struct {
	Revision    *int64  `json:"revision"`
	Fingerprint *string `json:"fingerprint"`
	Choice      string  `json:"choice,omitempty"`
	Guidance    string  `json:"guidance,omitempty"`
	// Omit the limit unless the operator explicitly accepts a runtime difference.
	RuntimeMinutes *int64 `json:"runtimeMinutes,omitempty"`
}

func (app *Handler) question(w http.ResponseWriter, r *http.Request) {
	job, ok := app.readJob(r)
	if !ok {
		jsonError(w, http.StatusNotFound, "job not found")
		return
	}
	question := reviewFor(job).Attention
	if question == nil {
		jsonError(w, http.StatusNotFound, "this job has no question to answer")
		return
	}

	app.setCSRFCookie(w)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(questionResponse{
		Question: question, Revision: job.Revision, Fingerprint: job.SourceFingerprint, CSRFToken: app.csrf,
	})
}

func (app *Handler) answer(w http.ResponseWriter, r *http.Request) {
	if !app.validOrigin(r) || !app.validToken(r, r.Header.Get("X-CSRF-Token")) {
		jsonError(w, http.StatusForbidden, "invalid request origin or CSRF token")
		return
	}
	if !hasContentType(r, "application/json") {
		jsonError(w, http.StatusUnsupportedMediaType, "send the answer as application/json")
		return
	}
	var input answerRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(new(any)) != io.EOF {
		jsonError(w, http.StatusBadRequest, "expected one JSON answer")
		return
	}
	if input.Revision == nil || input.Fingerprint == nil {
		jsonError(w, http.StatusBadRequest, "include the question revision and fingerprint")
		return
	}

	job, ok := app.readJob(r)
	if !ok {
		jsonError(w, http.StatusNotFound, "job not found")
		return
	}
	question := reviewFor(job).Attention
	const stale = "This item changed. Refresh the inbox before answering."
	if question == nil || *input.Revision != job.Revision || *input.Fingerprint != job.SourceFingerprint {
		jsonError(w, http.StatusConflict, stale)
		return
	}
	answer, err := input.forQuestion(job, *question)
	if err != nil {
		jsonError(w, http.StatusBadRequest, err.Error())
		return
	}
	err = app.config.Store.RequestReconsideration(r.Context(), job, answer, time.Now().UTC())
	if errors.Is(err, jobs.ErrConflict) {
		jsonError(w, http.StatusConflict, stale)
		return
	}
	if err != nil {
		jsonError(w, http.StatusInternalServerError, "could not save the answer")
		return
	}
	app.config.Wake(job.Service)
	w.WriteHeader(http.StatusNoContent)
}

// Choice values come straight from the question. Only the server needs to
// know whether a value identifies a Radarr file or a Lidarr release.
func (input answerRequest) forQuestion(job jobs.Job, question planning.Question) (planning.Answer, error) {
	if question.Kind == planning.Retry {
		if input.Choice != "" || input.Guidance != "" || input.RuntimeMinutes != nil {
			return planning.Answer{}, fmt.Errorf("a retry uses the previous answer")
		}
		return job.Answer, nil
	}

	guidance, tolerance, err := checkGuidance(input.Guidance, input.RuntimeMinutes, job.Service)
	if err != nil {
		return planning.Answer{}, err
	}
	if tolerance != 0 && !question.AllowRuntime {
		return planning.Answer{}, fmt.Errorf("this question does not offer a runtime override")
	}
	if question.Kind == planning.AcceptRuntime && tolerance == 0 {
		return planning.Answer{}, fmt.Errorf("choose the maximum runtime difference you accept")
	}
	if question.RequireGuidance && guidance == "" {
		return planning.Answer{}, fmt.Errorf("provide instructions before requesting another review")
	}

	// A runtime question can follow a file choice. Keep the chosen file.
	answer := job.Answer
	answer.Guidance = guidance
	answer.RuntimeToleranceMS = tolerance
	if len(question.Choices) == 0 && input.Choice == "" {
		return answer, nil
	}
	if !slices.ContainsFunc(question.Choices, func(choice planning.Choice) bool { return choice.Value == input.Choice }) {
		return planning.Answer{}, fmt.Errorf("choose one of the offered options")
	}
	switch question.Kind {
	case planning.ChooseRelease:
		answer.SelectedReleaseID, err = strconv.ParseInt(input.Choice, 10, 64)
	case planning.ChooseFile:
		answer.SelectedFileID = input.Choice
	}
	return answer, err
}

func jsonError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}

package repairui

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"strings"
	"time"
	"unicode"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
)

type availableActions map[string]bool

type jobResponse struct {
	Actions     availableActions   `json:"actions"`
	Question    *planning.Question `json:"question,omitempty"`
	Revision    int64              `json:"revision"`
	Fingerprint string             `json:"fingerprint"`
	CSRFToken   string             `json:"csrfToken"`
}

type actionRequest struct {
	Revision       *int64  `json:"revision"`
	Fingerprint    *string `json:"fingerprint"`
	Choice         string  `json:"choice,omitempty"`
	Guidance       string  `json:"guidance,omitempty"`
	RuntimeMinutes *int64  `json:"runtimeMinutes,omitempty"`
}

func (app *Handler) question(w http.ResponseWriter, r *http.Request) {
	job, ok := app.readActionJob(w, r)
	if !ok {
		return
	}
	review := reviewFor(job)
	if review.Attention == nil {
		jsonError(w, http.StatusNotFound, "this job has no question to answer")
		return
	}

	app.setCSRFCookie(w)
	writeJSON(w, app.jobActions(job, review))
}

func (app *Handler) jobActions(job jobs.Job, review review) jobResponse {
	return jobResponse{
		Actions: review.Actions, Question: review.Attention,
		Revision: job.Revision, Fingerprint: job.SourceFingerprint, CSRFToken: app.csrf,
	}
}

func (app *Handler) action(w http.ResponseWriter, r *http.Request) {
	var input actionRequest
	if !app.readAction(w, r, &input) {
		return
	}
	job, ok := app.readActionJob(w, r)
	if !ok {
		return
	}
	const stale = "This item changed. Refresh the page before trying again."
	if *input.Revision != job.Revision || *input.Fingerprint != job.SourceFingerprint {
		jsonError(w, http.StatusConflict, stale)
		return
	}

	review := reviewFor(job)
	action := r.PathValue("action")
	allowed, known := review.Actions[action]
	if !known {
		jsonError(w, http.StatusNotFound, "unknown action")
		return
	}
	if !allowed {
		jsonError(w, http.StatusConflict, stale)
		return
	}
	answer, err := input.forAction(action, job, review.Attention)
	if err != nil {
		jsonError(w, http.StatusBadRequest, err.Error())
		return
	}

	if action == "remove" {
		err = app.config.Store.RequestRemoval(r.Context(), job, time.Now().UTC())
	} else {
		err = app.config.Store.RequestReconsideration(r.Context(), job, answer, time.Now().UTC())
	}
	if errors.Is(err, jobs.ErrConflict) {
		jsonError(w, http.StatusConflict, stale)
		return
	}
	if err != nil {
		jsonError(w, http.StatusInternalServerError, "could not queue the request")
		return
	}

	// The request is already durable. Wake the scheduler to process it now.
	app.config.Wake(job.Service)
	w.WriteHeader(http.StatusNoContent)
}

func (app *Handler) readActionJob(w http.ResponseWriter, r *http.Request) (jobs.Job, bool) {
	var job jobs.Job
	id, err := requestedJobID(r)
	if err == nil {
		job, err = app.config.Store.Get(r.Context(), id)
	}
	if err != nil {
		status, message := jobReadError(err)
		jsonError(w, status, message)
	}
	return job, err == nil
}

func (input actionRequest) forAction(action string, job jobs.Job, question *planning.Question) (planning.Answer, error) {
	switch action {
	case "answer":
		return input.forQuestion(job, *question)
	case "reconsider":
		if input.Choice != "" {
			return planning.Answer{}, fmt.Errorf("a choice requires an open question")
		}
		guidance, limit, err := checkGuidance(input.Guidance, input.RuntimeMinutes, job.Service)
		return planning.Answer{Guidance: guidance, RuntimeToleranceMS: limit}, err
	case "remove":
		if input.Choice != "" || input.Guidance != "" || input.RuntimeMinutes != nil {
			return planning.Answer{}, fmt.Errorf("removal takes only a revision and fingerprint")
		}
		return planning.Answer{}, nil
	default:
		return planning.Answer{}, fmt.Errorf("unknown action")
	}
}

func (app *Handler) validOrigin(r *http.Request) bool {
	fetchSite := r.Header.Get("Sec-Fetch-Site")
	origin := r.Header.Get("Origin")
	return (fetchSite == "" || fetchSite == "same-origin") &&
		(app.origins[origin] || origin == "" && fetchSite == "same-origin")
}

func (app *Handler) validToken(r *http.Request, token string) bool {
	cookie, err := r.Cookie("repairr_csrf")
	return err == nil && sameToken(cookie.Value, app.csrf) && sameToken(token, app.csrf)
}

func hasContentType(r *http.Request, want string) bool {
	contentType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	return err == nil && contentType == want
}

func (app *Handler) readAction(w http.ResponseWriter, r *http.Request, input *actionRequest) bool {
	if !app.validOrigin(r) || !app.validToken(r, r.Header.Get("X-CSRF-Token")) {
		jsonError(w, http.StatusForbidden, "invalid request origin or CSRF token")
		return false
	}

	if !hasContentType(r, "application/json") {
		jsonError(w, http.StatusUnsupportedMediaType, "send the request as application/json")
		return false
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10))
	decoder.DisallowUnknownFields()
	if decoder.Decode(input) != nil || decoder.Decode(new(any)) != io.EOF {
		jsonError(w, http.StatusBadRequest, "expected one JSON request")
		return false
	}

	if input.Revision == nil || input.Fingerprint == nil {
		jsonError(w, http.StatusBadRequest, "include the job revision and fingerprint")
		return false
	}

	return true
}

func sameToken(left, right string) bool {
	return subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

func jsonError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}

func checkGuidance(text string, minutes *int64, service jobs.Service) (string, int64, error) {
	guidance := strings.TrimSpace(text)
	if len(guidance) > 2000 {
		return "", 0, fmt.Errorf("guidance exceeds 2000 bytes")
	}
	for _, character := range guidance {
		if unicode.IsControl(character) && character != '\n' && character != '\t' {
			return "", 0, fmt.Errorf("guidance contains control characters")
		}
	}

	var tolerance int64
	if minutes != nil {
		if service != jobs.Radarr || *minutes < 1 || *minutes > 60 {
			return "", 0, fmt.Errorf("Radarr runtime tolerance must be 1–60 minutes")
		}
		tolerance = *minutes * 60 * 1000
	}

	return guidance, tolerance, nil
}

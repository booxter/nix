package repairui

import (
	"crypto/subtle"
	"errors"
	"fmt"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
)

func (app *Handler) action(w http.ResponseWriter, r *http.Request) {
	if !app.validForm(w, r) {
		return
	}
	job, ok := app.readJob(w, r)
	if !ok {
		return
	}
	if r.PathValue("action") == "respond" {
		app.respond(w, r, job)
		return
	}

	action := jobs.Reconsider
	switch r.PathValue("action") {
	case "reconsider":
	case "remove":
		action = jobs.Delete
	default:
		http.NotFound(w, r)
		return
	}

	guidance, tolerance, err := parseGuidance(r, job.Service)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := app.config.Store.RequestAction(r.Context(), job.ID, action, guidance, tolerance, time.Now().UTC()); err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, jobs.ErrConflict) {
			status = http.StatusConflict
		}
		http.Error(w, "job changed or is already active", status)
		return
	}

	// The database makes the request durable; this signal only avoids waiting
	// for the scheduler's next poll. There is no second action spool to update.
	app.config.Wake(job.Service)
	http.Redirect(w, r, fmt.Sprintf("/jobs/%d", job.ID), http.StatusSeeOther)
}

func (app *Handler) respond(w http.ResponseWriter, r *http.Request, job jobs.Job) {
	entry := present(job)
	revision, err := strconv.ParseInt(r.PostForm.Get("revision"), 10, 64)
	if err != nil || entry.Attention == nil || revision != job.Revision || r.PostForm.Get("fingerprint") != job.SourceFingerprint {
		http.Error(w, "This item changed. Refresh the inbox before answering.", http.StatusConflict)
		return
	}
	answer, err := readAnswer(r, job, *entry.Attention)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := app.config.Store.RequestReconsideration(r.Context(), job, answer, time.Now().UTC()); err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, jobs.ErrConflict) {
			status = http.StatusConflict
		}
		http.Error(w, "This item changed. Refresh the inbox before answering.", status)
		return
	}
	app.config.Wake(job.Service)
	http.Redirect(w, r, "/?submitted="+strconv.FormatInt(job.ID, 10), http.StatusSeeOther)
}

// A retry reuses the saved answer. For a new answer, accept only the choices
// and overrides offered by this question.
func readAnswer(r *http.Request, job jobs.Job, request planning.Question) (planning.Answer, error) {
	if request.Kind == planning.Retry {
		return job.Answer, nil
	}
	guidance, tolerance, err := parseGuidance(r, job.Service)
	if err != nil {
		return planning.Answer{}, err
	}
	if tolerance != 0 && !request.AllowRuntime {
		return planning.Answer{}, fmt.Errorf("this question does not offer a runtime override")
	}
	if request.Kind == planning.AcceptRuntime && tolerance == 0 {
		return planning.Answer{}, fmt.Errorf("choose the maximum runtime difference you accept")
	}
	if request.RequireGuidance && guidance == "" {
		return planning.Answer{}, fmt.Errorf("provide instructions before requesting another review")
	}
	// A follow-up question about runtime can refer to a file already chosen.
	answer := job.Answer
	answer.Guidance = guidance
	answer.RuntimeToleranceMS = tolerance
	if len(request.Choices) == 0 {
		return answer, nil
	}
	for _, choice := range request.Choices {
		if choice.Value != r.PostForm.Get("selection") {
			continue
		}
		switch request.Kind {
		case planning.ChooseRelease:
			answer.SelectedReleaseID, err = strconv.ParseInt(choice.Value, 10, 64)
		case planning.ChooseFile:
			answer.SelectedFileID = choice.Value
		}
		return answer, err
	}
	return planning.Answer{}, fmt.Errorf("choose one of the offered options")
}

func (app *Handler) validForm(w http.ResponseWriter, r *http.Request) bool {
	fetchSite := r.Header.Get("Sec-Fetch-Site")
	origin := r.Header.Get("Origin")
	if fetchSite != "" && fetchSite != "same-origin" ||
		!app.origins[origin] && !(origin == "" && fetchSite == "same-origin") {
		http.Error(w, "invalid request origin", http.StatusForbidden)
		return false
	}

	contentType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || contentType != "application/x-www-form-urlencoded" {
		http.Error(w, "invalid form content type", http.StatusUnsupportedMediaType)
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", http.StatusBadRequest)
		return false
	}

	cookie, err := r.Cookie("repairr_csrf")
	if err != nil || !sameToken(cookie.Value, app.csrf) || !sameToken(r.PostForm.Get("csrf_token"), app.csrf) {
		http.Error(w, "invalid CSRF token", http.StatusForbidden)
		return false
	}

	return true
}

func sameToken(left, right string) bool {
	return subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

func parseGuidance(r *http.Request, service jobs.Service) (string, int64, error) {
	guidance := strings.TrimSpace(r.PostForm.Get("guidance"))
	if len(guidance) > 2000 {
		return "", 0, fmt.Errorf("guidance exceeds 2000 bytes")
	}
	for _, character := range guidance {
		if unicode.IsControl(character) && character != '\n' && character != '\t' {
			return "", 0, fmt.Errorf("guidance contains control characters")
		}
	}

	var tolerance int64
	if r.PostForm.Get("override_runtime_difference") != "" {
		minutes, err := strconv.ParseInt(r.PostForm.Get("runtime_minutes"), 10, 64)
		if err != nil || service != jobs.Radarr || minutes < 1 || minutes > 60 {
			return "", 0, fmt.Errorf("Radarr runtime tolerance must be 1–60 minutes")
		}
		tolerance = minutes * 60 * 1000
	}

	return guidance, tolerance, nil
}

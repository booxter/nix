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
)

func (app *Handler) action(w http.ResponseWriter, r *http.Request) {
	if !app.validForm(w, r) {
		return
	}
	job, ok := app.readJob(r)
	if !ok {
		http.NotFound(w, r)
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

func (app *Handler) validForm(w http.ResponseWriter, r *http.Request) bool {
	if !app.validOrigin(r) {
		http.Error(w, "invalid request origin", http.StatusForbidden)
		return false
	}

	if !hasContentType(r, "application/x-www-form-urlencoded") {
		http.Error(w, "invalid form content type", http.StatusUnsupportedMediaType)
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", http.StatusBadRequest)
		return false
	}

	if !app.validToken(r, r.PostForm.Get("csrf_token")) {
		http.Error(w, "invalid CSRF token", http.StatusForbidden)
		return false
	}

	return true
}

func sameToken(left, right string) bool {
	return subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

func parseGuidance(r *http.Request, service jobs.Service) (string, int64, error) {
	var minutes *int64
	if r.PostForm.Get("override_runtime_difference") != "" {
		value, err := strconv.ParseInt(r.PostForm.Get("runtime_minutes"), 10, 64)
		if err != nil {
			return "", 0, fmt.Errorf("enter the runtime difference in whole minutes")
		}
		minutes = &value
	}
	return checkGuidance(r.PostForm.Get("guidance"), minutes, service)
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

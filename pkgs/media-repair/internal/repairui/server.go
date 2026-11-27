package repairui

import (
	"bytes"
	"crypto/rand"
	"embed"
	"encoding/base64"
	"errors"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"strconv"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
)

//go:embed page.html
var templates embed.FS

//go:embed style.css
var Style string

//go:embed dom.js actions.js job.js listing.js
var scripts embed.FS

type Config struct {
	Store     *jobs.Store
	Origins   []string
	QueueURLs map[jobs.Service]string
	Wake      func(jobs.Service)
}

type Handler struct {
	config  Config
	page    *template.Template
	origins map[string]bool
	csrf    string
}

type item struct {
	review
	Job         jobs.Job
	Subject     string
	Status      string
	Explanation string
	NextStep    string
}

type review struct {
	Decision  decision
	Outcome   jobs.Outcome
	Attention *planning.Question
	Actions   availableActions
}

type decision struct {
	Action          string                      `json:"action"`
	Reason          string                      `json:"reason"`
	Explanation     string                      `json:"explanation"`
	MissingEvidence []contracts.MissingEvidence `json:"missing_evidence"`
}

type page struct {
	ListURL  string
	Title    string
	Service  jobs.Service
	History  bool
	JobID    int64
	State    string
	Query    string
	Inbox    bool
	Activity bool
	Notice   string
}

func New(config Config) (http.Handler, error) {
	parsed, err := template.ParseFS(templates, "page.html")
	if err != nil {
		return nil, err
	}

	origins := make(map[string]bool, len(config.Origins))
	for _, raw := range config.Origins {
		origin, err := url.Parse(raw)
		if err != nil || origin.Scheme != "https" || origin.Host == "" || origin.User != nil ||
			(origin.Path != "" && origin.Path != "/") || origin.RawQuery != "" || origin.Fragment != "" {
			return nil, fmt.Errorf("invalid Repairr origin %q", raw)
		}
		origins[origin.Scheme+"://"+origin.Host] = true
	}

	token := make([]byte, 32)
	if _, err := rand.Read(token); err != nil {
		return nil, err
	}
	app := &Handler{
		config:  config,
		page:    parsed,
		origins: origins,
		csrf:    base64.RawURLEncoding.EncodeToString(token),
	}

	router := http.NewServeMux()
	router.HandleFunc("GET /{$}", app.list)
	router.HandleFunc("GET /activity", app.list)
	router.HandleFunc("GET /lidarr", app.list)
	router.HandleFunc("GET /radarr", app.list)
	router.HandleFunc("GET /history", app.list)
	router.HandleFunc("GET /jobs/{id}", app.detail)
	router.HandleFunc("GET /jobs/{id}/remove", app.detail)
	router.HandleFunc("GET /api/jobs", app.listJobs)
	router.HandleFunc("GET /api/jobs/{id}", app.jobInfo)
	router.HandleFunc("GET /api/jobs/{id}/question", app.question)
	router.HandleFunc("POST /api/jobs/{id}/{action}", app.action)
	router.HandleFunc("GET /assets/style.css", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		_, _ = w.Write([]byte(Style))
	})
	router.Handle("GET /assets/", http.StripPrefix("/assets/", http.FileServerFS(scripts)))
	router.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		router.ServeHTTP(w, r)
	}), nil
}

func (app *Handler) list(w http.ResponseWriter, r *http.Request) {
	filter := readListFilter(r.URL.Query())
	view := page{State: filter.State, Query: filter.Query}
	switch {
	case r.URL.Path == "/history":
		view.Title, view.History = "History", true
		filter.View = "history"
	case r.URL.Path == "/activity" || filter.State != "":
		view.Title, view.Activity = "Queue activity", true
		filter.View = "activity"
	default:
		view.Title, view.Inbox = "Needs you", true
		filter.View = "inbox"
	}
	if r.URL.Path == "/radarr" {
		filter.Service = jobs.Radarr
	} else if r.URL.Path == "/lidarr" {
		filter.Service = jobs.Lidarr
	}
	if err := filter.validate(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	view.Service = filter.Service
	if r.URL.Query().Get("submitted") != "" {
		view.Notice = "Your request was saved. Repairr will review it; follow its progress in Queue activity."
	}

	query := r.URL.Query()
	query.Del("submitted")
	query.Set("view", filter.View)
	query.Set("service", string(filter.Service))
	view.ListURL = "/api/jobs?" + query.Encode()
	app.render(w, view)
}

func (app *Handler) detail(w http.ResponseWriter, r *http.Request) {
	id, err := requestedJobID(r)
	if err != nil {
		status, message := jobReadError(err)
		http.Error(w, message, status)
		return
	}

	app.render(w, page{Title: "Item details", JobID: id})
}

func requestedJobID(r *http.Request) (int64, error) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		return 0, jobs.ErrNotFound
	}
	return id, nil
}

func (app *Handler) readDetail(r *http.Request) (jobs.Job, []jobs.Attempt, error) {
	id, err := requestedJobID(r)
	if err != nil {
		return jobs.Job{}, nil, err
	}
	return app.config.Store.JobWithAttempts(r.Context(), id)
}

func jobReadError(err error) (int, string) {
	if errors.Is(err, jobs.ErrNotFound) {
		return http.StatusNotFound, "job not found"
	}
	return http.StatusInternalServerError, "could not read job"
}

func (app *Handler) render(w http.ResponseWriter, view page) {
	var output bytes.Buffer
	if err := app.page.Execute(&output, view); err != nil {
		http.Error(w, "render Repairr", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = output.WriteTo(w)
}

func (app *Handler) setCSRFCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name: "repairr_csrf", Value: app.csrf, Path: "/",
		Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode,
	})
}

package repairui

import (
	"bytes"
	"crypto/rand"
	"embed"
	"encoding/base64"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
)

//go:embed page.html
var templates embed.FS

//go:embed style.css
var Style string

//go:embed local-time.js actions.js
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
	CSRF        string
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
	Title          string
	Service        jobs.Service
	History        bool
	Items          []item
	Selected       *item
	Attempts       []jobs.Attempt
	ConfirmRemoval bool
	QueueURL       string
	State          string
	Query          string
	Inbox          bool
	Activity       bool
	InboxCount     int
	ActivityCount  int
	Notice         string
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
	view := page{Title: "Needs you", History: r.URL.Path == "/history"}
	view.State = r.URL.Query().Get("state")
	view.Query = strings.TrimSpace(r.URL.Query().Get("q"))
	view.Activity = r.URL.Path == "/activity" || view.State != ""
	view.Inbox = !view.Activity && !view.History
	if view.Activity {
		view.Title = "Queue activity"
	} else if view.History {
		view.Title = "History"
	}
	view.Service = jobs.Service(r.URL.Query().Get("service"))
	if r.URL.Path == "/radarr" {
		view.Service = jobs.Radarr
	} else if r.URL.Path == "/lidarr" {
		view.Service = jobs.Lidarr
	}
	if view.Service != "" && view.Service != jobs.Radarr && view.Service != jobs.Lidarr {
		http.Error(w, "unknown service", http.StatusBadRequest)
		return
	}
	if r.URL.Query().Get("submitted") != "" {
		view.Notice = "Your request was saved. Repairr will review it; follow its progress in Queue activity."
	}

	for _, service := range []jobs.Service{jobs.Lidarr, jobs.Radarr} {
		if view.Service != "" && view.Service != service {
			continue
		}
		listed, err := app.config.Store.List(r.Context(), service)
		if err != nil {
			http.Error(w, "read jobs", http.StatusInternalServerError)
			return
		}

		for _, job := range listed {
			historical := !job.InQueue || job.State == jobs.Removed || job.State == jobs.Imported
			entry := present(job)
			needsOperator := entry.Attention != nil || job.PendingAction == jobs.ConfirmRemoval
			entry.CSRF = app.csrf
			if !historical {
				view.ActivityCount++
				if needsOperator {
					view.InboxCount++
				}
			}
			if historical != view.History || view.State != "" && string(job.State) != view.State {
				continue
			}
			if view.Inbox && !needsOperator {
				continue
			}
			searchable := strings.Join([]string{
				entry.Subject, job.Title, entry.Status, entry.Explanation, job.Reason, job.CollectionError,
			}, " ")
			if view.Query != "" && !strings.Contains(strings.ToLower(searchable), strings.ToLower(view.Query)) {
				continue
			}
			view.Items = append(view.Items, entry)
		}
	}
	app.render(w, view)
}

func (app *Handler) detail(w http.ResponseWriter, r *http.Request) {
	job, ok := app.readJob(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	attempts, err := app.config.Store.Attempts(r.Context(), job.ID)
	if err != nil {
		http.Error(w, "read attempts", http.StatusInternalServerError)
		return
	}

	selected := present(job)
	selected.CSRF = app.csrf
	app.render(w, page{
		Title:          "Item details",
		Service:        job.Service,
		Selected:       &selected,
		Attempts:       attempts,
		ConfirmRemoval: selected.Actions["remove"] && r.URL.Path == fmt.Sprintf("/jobs/%d/remove", job.ID),
		QueueURL:       app.config.QueueURLs[job.Service],
	})
}

func (app *Handler) readJob(r *http.Request) (jobs.Job, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		return jobs.Job{}, false
	}

	job, err := app.config.Store.Get(r.Context(), id)
	return job, err == nil
}

func (app *Handler) render(w http.ResponseWriter, view page) {
	var output bytes.Buffer
	if err := app.page.Execute(&output, view); err != nil {
		http.Error(w, "render Repairr", http.StatusInternalServerError)
		return
	}

	app.setCSRFCookie(w)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = output.WriteTo(w)
}

func (app *Handler) setCSRFCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name: "repairr_csrf", Value: app.csrf, Path: "/",
		Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode,
	})
}

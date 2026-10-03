package repairui

import (
	"bytes"
	"crypto/rand"
	"embed"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"strconv"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

//go:embed page.html
var templates embed.FS

//go:embed style.css
var Style string

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
	Job      jobs.Job
	Decision decision
	CanAct   bool
}

type decision struct {
	Action      string `json:"action"`
	Reason      string `json:"reason"`
	Explanation string `json:"explanation"`
}

type page struct {
	Title          string
	Service        jobs.Service
	History        bool
	Items          []item
	Selected       *item
	Attempts       []jobs.Attempt
	CSRF           string
	ConfirmRemoval bool
	QueueURL       string
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
	router.HandleFunc("GET /lidarr", app.list)
	router.HandleFunc("GET /radarr", app.list)
	router.HandleFunc("GET /history", app.list)
	router.HandleFunc("GET /jobs/{id}", app.detail)
	router.HandleFunc("GET /jobs/{id}/remove", app.detail)
	router.HandleFunc("POST /jobs/{id}/{action}", app.action)
	router.HandleFunc("GET /assets/style.css", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		_, _ = w.Write([]byte(Style))
	})
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
	view := page{Title: "Repairr", CSRF: app.csrf, History: r.URL.Path == "/history"}
	if r.URL.Path == "/radarr" {
		view.Service = jobs.Radarr
	} else if r.URL.Path == "/lidarr" {
		view.Service = jobs.Lidarr
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
			filter := r.URL.Query().Get("state")
			if historical != view.History || filter != "" && string(job.State) != filter {
				continue
			}
			view.Items = append(view.Items, present(job))
		}
	}

	app.render(w, view)
}

func (app *Handler) detail(w http.ResponseWriter, r *http.Request) {
	job, ok := app.readJob(w, r)
	if !ok {
		return
	}
	attempts, err := app.config.Store.Attempts(r.Context(), job.ID)
	if err != nil {
		http.Error(w, "read attempts", http.StatusInternalServerError)
		return
	}

	selected := present(job)
	app.render(w, page{
		Title:          job.Title,
		Service:        job.Service,
		Selected:       &selected,
		Attempts:       attempts,
		CSRF:           app.csrf,
		ConfirmRemoval: r.URL.Path == fmt.Sprintf("/jobs/%d/remove", job.ID),
		QueueURL:       app.config.QueueURLs[job.Service],
	})
}

func (app *Handler) readJob(w http.ResponseWriter, r *http.Request) (jobs.Job, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		http.NotFound(w, r)
		return jobs.Job{}, false
	}

	job, err := app.config.Store.Get(r.Context(), id)
	if err != nil {
		http.NotFound(w, r)
		return jobs.Job{}, false
	}

	return job, true
}

func (app *Handler) render(w http.ResponseWriter, view page) {
	var output bytes.Buffer
	if err := app.page.Execute(&output, view); err != nil {
		http.Error(w, "render Repairr", http.StatusInternalServerError)
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name: "repairr_csrf", Value: app.csrf, Path: "/",
		Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode,
	})
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = output.WriteTo(w)
}

func present(job jobs.Job) item {
	view := item{
		Job:    job,
		CanAct: job.InQueue && job.State != jobs.Running && job.State != jobs.Importing && job.State != jobs.Removing && job.State != jobs.Removed,
	}
	if len(job.Plan) != 0 {
		_ = json.Unmarshal(job.Plan, &view.Decision)
	}

	return view
}

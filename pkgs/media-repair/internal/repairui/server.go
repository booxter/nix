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

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

//go:embed page.html
var templates embed.FS

//go:embed style.css
var Style string

//go:embed local-time.js
var localTimeScript string

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
	Job         jobs.Job
	Decision    decision
	CanAct      bool
	Subject     string
	Status      string
	Explanation string
	NextStep    string
	Group       string
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
	State          string
	Query          string
	Groups         []itemGroup
}

type itemGroup struct {
	Key         string
	Title       string
	Description string
	Items       []item
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
	router.HandleFunc("GET /assets/local-time.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		_, _ = w.Write([]byte(localTimeScript))
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
	view.State = r.URL.Query().Get("state")
	view.Query = strings.TrimSpace(r.URL.Query().Get("q"))
	if view.State == string(jobs.Blocked) {
		view.Title = "Blocked items"
	}
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
			if historical != view.History || view.State != "" && string(job.State) != view.State {
				continue
			}
			entry := present(job)
			searchable := strings.Join([]string{
				entry.Subject, job.Title, entry.Status, entry.Explanation, job.Reason, job.CollectionError,
			}, " ")
			if view.Query != "" && !strings.Contains(strings.ToLower(searchable), strings.ToLower(view.Query)) {
				continue
			}
			view.Items = append(view.Items, entry)
		}
	}
	if view.State == string(jobs.Blocked) {
		view.Groups = blockedGroups(view.Items)
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
		Title:          "Item details",
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

func blockedGroups(items []item) []itemGroup {
	groups := []itemGroup{
		{Key: "planner", Title: "Planner could not decide", Description: "These are failed planning attempts, not decisions that the media cannot be repaired."},
		{Key: "changed", Title: "Import stopped by a safety check", Description: "Evidence changed after planning. Review the current files and matches before trying again."},
		{Key: "inspection", Title: "Files could not be inspected", Description: "Repairr needs readable, supported files before it can make a plan."},
		{Key: "review", Title: "Needs another look", Description: "These items need a review of their current queue entry or previous result."},
		{Key: "decision", Title: "No automatic repair chosen", Description: "The planner reviewed these items. Read each decision to see why it declined and what information could help."},
		{Key: "waiting", Title: "Waiting on the download or queue", Description: "Repairr cannot process these entries in their current queue state. Check their status in Lidarr or Radarr."},
		{Key: "removal", Title: "Queue removal pending", Description: "Removal affects queue tracking only. The downloaded files are retained."},
	}
	var populated []itemGroup
	for _, group := range groups {
		for _, entry := range items {
			if entry.Group == group.Key {
				group.Items = append(group.Items, entry)
			}
		}
		if len(group.Items) > 0 {
			populated = append(populated, group)
		}
	}
	return populated
}

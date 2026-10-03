package main

import (
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"fmt"
	"html/template"
	"io"
	"mime"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/queueaction"
	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
	"github.com/booxter/nix-config/media-repair/internal/repairui"
	"github.com/booxter/nix-config/media-repair/internal/review"
	"github.com/booxter/nix-config/media-repair/internal/wake"
)

//go:embed templates/page.html
var assets embed.FS

type source struct {
	service  review.Service
	store    *review.Store
	requests *reconsideration.Store
	actions  *queueaction.Store
	trigger  *wake.Store
	queueURL string
}

type applicationHandler struct {
	template       *template.Template
	sources        []source
	style          []byte
	csrfToken      string
	allowedOrigins map[string]struct{}
	now            func() time.Time
}

type itemView struct {
	Item                  review.Item
	Service               review.Service
	QueueURL              string
	Current               bool
	CanReconsider         bool
	ReconsiderationQueued bool
	CanRemove             bool
	RemovalQueued         bool
}

type sourceStatus struct {
	Service     review.Service
	GeneratedAt *time.Time
	Available   bool
	Error       string
	Current     int
	History     int
}

type pageView struct {
	Title            string
	ActiveService    review.Service
	History          bool
	Items            []itemView
	Case             *itemView
	Sources          []sourceStatus
	Filter           string
	CSRFToken        string
	Submitted        bool
	RemovalSubmitted bool
	ConfirmRemoval   bool
}

const csrfCookieName = "repairr_csrf"

func newHandler(configuration config) (http.Handler, error) {
	lidarrStore, err := review.NewStore(configuration.LidarrSnapshot)
	if err != nil {
		return nil, fmt.Errorf("configure Lidarr review source: %w", err)
	}
	radarrStore, err := review.NewStore(configuration.RadarrSnapshot)
	if err != nil {
		return nil, fmt.Errorf("configure Radarr review source: %w", err)
	}
	lidarrRequests, err := reconsideration.NewStore(
		configuration.LidarrRequests, reconsideration.ServiceLidarr,
	)
	if err != nil {
		return nil, fmt.Errorf("configure Lidarr reconsideration inbox: %w", err)
	}
	radarrRequests, err := reconsideration.NewStore(
		configuration.RadarrRequests, reconsideration.ServiceRadarr,
	)
	if err != nil {
		return nil, fmt.Errorf("configure Radarr reconsideration inbox: %w", err)
	}
	lidarrActions, err := queueaction.NewStore(configuration.LidarrActions, queueaction.ServiceLidarr)
	if err != nil {
		return nil, fmt.Errorf("configure Lidarr operator action inbox: %w", err)
	}
	radarrActions, err := queueaction.NewStore(configuration.RadarrActions, queueaction.ServiceRadarr)
	if err != nil {
		return nil, fmt.Errorf("configure Radarr operator action inbox: %w", err)
	}
	lidarrTrigger, err := wake.NewStore(configuration.LidarrTrigger)
	if err != nil {
		return nil, fmt.Errorf("configure Lidarr controller trigger: %w", err)
	}
	radarrTrigger, err := wake.NewStore(configuration.RadarrTrigger)
	if err != nil {
		return nil, fmt.Errorf("configure Radarr controller trigger: %w", err)
	}
	csrfBytes := make([]byte, 32)
	if _, err := io.ReadFull(rand.Reader, csrfBytes); err != nil {
		return nil, fmt.Errorf("generate CSRF token: %w", err)
	}
	csrfToken := base64.RawURLEncoding.EncodeToString(csrfBytes)
	publicOrigin, err := httpsOrigin(configuration.PublicURL)
	if err != nil {
		return nil, fmt.Errorf("parse Repairr public URL: %w", err)
	}
	allowedOrigins := map[string]struct{}{publicOrigin: {}}
	for _, raw := range configuration.AllowedOrigins {
		origin, err := httpsOrigin(raw)
		if err != nil {
			return nil, fmt.Errorf("parse Repairr allowed origin: %w", err)
		}
		allowedOrigins[origin] = struct{}{}
	}
	functions := template.FuncMap{
		"formatTime": func(value any) string {
			var instant time.Time
			switch typed := value.(type) {
			case time.Time:
				instant = typed
			case *time.Time:
				if typed == nil {
					return "—"
				}
				instant = *typed
			default:
				return "—"
			}
			return instant.Local().Format("2006-01-02 15:04 MST")
		},
		"formatDurationMS": func(milliseconds int64) string {
			return (time.Duration(milliseconds) * time.Millisecond).String()
		},
		"reasonLabel": func(value string) string {
			label := strings.ReplaceAll(value, "_", " ")
			if label == "" {
				return label
			}
			return strings.ToUpper(label[:1]) + label[1:]
		},
		"stateLabel": stateLabel,
		"serviceLabel": func(value review.Service) string {
			if value == review.ServiceLidarr {
				return "Lidarr"
			}
			return "Radarr"
		},
		"caseURL": func(caseID string) string { return "/cases/" + caseID },
	}
	page, err := template.New("page.html").Funcs(functions).ParseFS(assets, "templates/page.html")
	if err != nil {
		return nil, fmt.Errorf("parse repair review template: %w", err)
	}
	style := []byte(repairui.Style)
	app := &applicationHandler{
		template: page, style: style, csrfToken: csrfToken,
		allowedOrigins: allowedOrigins, now: time.Now,
		sources: []source{
			{
				service: review.ServiceLidarr, store: lidarrStore,
				requests: lidarrRequests, queueURL: configuration.LidarrURL,
				actions: lidarrActions, trigger: lidarrTrigger,
			},
			{
				service: review.ServiceRadarr, store: radarrStore,
				requests: radarrRequests, queueURL: configuration.RadarrURL,
				actions: radarrActions, trigger: radarrTrigger,
			},
		},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", app.pageHandler)
	mux.HandleFunc("/lidarr", app.pageHandler)
	mux.HandleFunc("/radarr", app.pageHandler)
	mux.HandleFunc("/history", app.pageHandler)
	mux.HandleFunc("/cases/", app.pageHandler)
	mux.HandleFunc("POST /cases/{caseID}/reconsider", app.reconsiderHandler)
	mux.HandleFunc("GET /cases/{caseID}/remove", app.confirmRemoveHandler)
	mux.HandleFunc("POST /cases/{caseID}/remove", app.removeHandler)
	mux.HandleFunc("/assets/style.css", app.styleHandler)
	mux.HandleFunc("/-/ready", app.readyHandler)
	return securityHeaders(mux), nil
}

func (app *applicationHandler) pageHandler(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		writer.Header().Set("Allow", "GET, HEAD")
		http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	view, status, err := app.buildPage(request)
	if err != nil {
		http.Error(writer, err.Error(), status)
		return
	}
	writer.Header().Set("Content-Type", "text/html; charset=utf-8")
	app.setCSRFCookie(writer)
	if request.Method == http.MethodHead {
		return
	}
	if err := app.template.Execute(writer, view); err != nil {
		http.Error(writer, "render review page", http.StatusInternalServerError)
	}
}

func (app *applicationHandler) buildPage(request *http.Request) (pageView, int, error) {
	snapshots, statuses := app.readSnapshots()
	view := pageView{
		Title: "Repair review", Sources: statuses, Filter: request.URL.Query().Get("state"),
		CSRFToken: app.csrfToken, Submitted: request.URL.Query().Get("submitted") == "1",
		RemovalSubmitted: request.URL.Query().Get("removed") == "1",
	}
	switch request.URL.Path {
	case "/":
		view.Title = "Repair review"
		view.Items = currentItems(app.sources, snapshots, "")
	case "/lidarr":
		view.Title = "Lidarr repair review"
		view.ActiveService = review.ServiceLidarr
		view.Items = currentItems(app.sources, snapshots, review.ServiceLidarr)
	case "/radarr":
		view.Title = "Radarr repair review"
		view.ActiveService = review.ServiceRadarr
		view.Items = currentItems(app.sources, snapshots, review.ServiceRadarr)
	case "/history":
		view.Title = "Repair history"
		view.History = true
		view.Items = historyItems(app.sources, snapshots)
	default:
		if !strings.HasPrefix(request.URL.Path, "/cases/") {
			return pageView{}, http.StatusNotFound, fmt.Errorf("page not found")
		}
		caseID := strings.TrimPrefix(request.URL.Path, "/cases/")
		if caseID == "" || strings.Contains(caseID, "/") {
			return pageView{}, http.StatusNotFound, fmt.Errorf("case not found")
		}
		item, found := findCase(app.sources, snapshots, caseID)
		if !found {
			return pageView{}, http.StatusNotFound, fmt.Errorf("case not found")
		}
		item, mergeErr := app.withLatestReconsideration(item)
		if mergeErr != nil {
			return pageView{}, http.StatusInternalServerError, mergeErr
		}
		item, mergeErr = app.withLatestQueueRemoval(item)
		if mergeErr != nil {
			return pageView{}, http.StatusInternalServerError, mergeErr
		}
		view.Title = "Repair case"
		view.Case = &item
	}
	if view.Filter != "" && view.Case == nil {
		filtered := view.Items[:0]
		for _, item := range view.Items {
			if string(item.Item.State) == view.Filter {
				filtered = append(filtered, item)
			}
		}
		view.Items = filtered
	}
	return view, http.StatusOK, nil
}

func (app *applicationHandler) confirmRemoveHandler(writer http.ResponseWriter, request *http.Request) {
	caseID := request.PathValue("caseID")
	clone := request.Clone(request.Context())
	clone.URL.Path = "/cases/" + caseID
	view, status, err := app.buildPage(clone)
	if err != nil {
		http.Error(writer, err.Error(), status)
		return
	}
	if view.Case == nil || !view.Case.CanRemove {
		http.Error(writer, "current removable case not found", http.StatusNotFound)
		return
	}
	view.Title = "Confirm queue removal"
	view.ConfirmRemoval = true
	writer.Header().Set("Content-Type", "text/html; charset=utf-8")
	app.setCSRFCookie(writer)
	if err := app.template.Execute(writer, view); err != nil {
		http.Error(writer, "render queue removal confirmation", http.StatusInternalServerError)
	}
}

func (app *applicationHandler) removeHandler(writer http.ResponseWriter, request *http.Request) {
	if err := app.validateForm(writer, request); err != nil {
		return
	}
	caseID := request.PathValue("caseID")
	snapshots, _ := app.readSnapshots()
	entry, source, found := findCurrentCase(app.sources, snapshots, caseID)
	if !found || entry.QueueIdentity == nil {
		http.Error(writer, "current removable case not found", http.StatusNotFound)
		return
	}
	latest, pending, err := source.actions.Latest(caseID)
	if err != nil {
		http.Error(writer, "read queue removal requests", http.StatusInternalServerError)
		return
	}
	if pending && (entry.QueueRemoval == nil || entry.QueueRemoval.RequestID != latest.RequestID ||
		entry.QueueRemoval.State != queueaction.StateFailed) {
		http.Error(writer, "queue removal is already pending", http.StatusConflict)
		return
	}
	action, err := queueaction.NewRequest(
		queueaction.Service(source.service), caseID, *entry.QueueIdentity, app.now().UTC(),
	)
	if err != nil {
		http.Error(writer, err.Error(), http.StatusUnprocessableEntity)
		return
	}
	if _, err := source.actions.Submit(action); err != nil {
		http.Error(writer, "store queue removal request", http.StatusInternalServerError)
		return
	}
	if err := source.trigger.Signal(); err != nil {
		http.Error(writer, "wake repair controller", http.StatusInternalServerError)
		return
	}
	http.Redirect(writer, request, "/cases/"+url.PathEscape(caseID)+"?removed=1", http.StatusSeeOther)
}

func (app *applicationHandler) validateForm(writer http.ResponseWriter, request *http.Request) error {
	if !app.requestOriginAllowed(request) {
		http.Error(writer, "invalid request origin", http.StatusForbidden)
		return fmt.Errorf("invalid request origin")
	}
	mediaType, _, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/x-www-form-urlencoded" {
		http.Error(writer, "invalid form submission", http.StatusUnsupportedMediaType)
		return fmt.Errorf("invalid form submission")
	}
	request.Body = http.MaxBytesReader(writer, request.Body, 8<<10)
	if err := request.ParseForm(); err != nil {
		http.Error(writer, "invalid form submission", http.StatusBadRequest)
		return err
	}
	cookie, err := request.Cookie(csrfCookieName)
	if err != nil || !sameToken(cookie.Value, app.csrfToken) ||
		!sameToken(request.PostForm.Get("csrf_token"), app.csrfToken) {
		http.Error(writer, "invalid CSRF token", http.StatusForbidden)
		return fmt.Errorf("invalid CSRF token")
	}
	return nil
}

func (app *applicationHandler) reconsiderHandler(
	writer http.ResponseWriter,
	request *http.Request,
) {
	if err := app.validateForm(writer, request); err != nil {
		return
	}
	caseID := request.PathValue("caseID")
	snapshots, _ := app.readSnapshots()
	entry, source, found := findCurrentCase(app.sources, snapshots, caseID)
	if !found || entry.Decision == nil {
		http.Error(writer, "current decided case not found", http.StatusNotFound)
		return
	}
	pending, err := reconsiderationPending(source.requests, entry)
	if err != nil {
		http.Error(writer, "read reconsideration requests", http.StatusInternalServerError)
		return
	}
	if pending {
		http.Error(writer, "reconsideration is already pending", http.StatusConflict)
		return
	}
	guidance := strings.TrimSpace(request.PostForm.Get("guidance"))
	policyOverrides, err := parsePolicyOverrides(
		source.service,
		request.PostForm.Get("override_runtime_difference"),
		request.PostForm.Get("maximum_runtime_difference_minutes"),
	)
	if err != nil {
		http.Error(writer, err.Error(), http.StatusUnprocessableEntity)
		return
	}
	reconsiderationRequest, err := reconsideration.NewRequest(
		reconsideration.Service(source.service), caseID, guidance, policyOverrides, app.now().UTC(),
	)
	if err != nil {
		http.Error(writer, err.Error(), http.StatusUnprocessableEntity)
		return
	}
	if _, err := source.requests.Submit(reconsiderationRequest); err != nil {
		http.Error(writer, "store reconsideration request", http.StatusInternalServerError)
		return
	}
	if err := source.trigger.Signal(); err != nil {
		http.Error(writer, "wake repair controller", http.StatusInternalServerError)
		return
	}
	http.Redirect(writer, request, "/cases/"+url.PathEscape(caseID)+"?submitted=1", http.StatusSeeOther)
}

func parsePolicyOverrides(
	service review.Service,
	enabled, maximumMinutes string,
) (*reconsideration.PolicyOverrides, error) {
	if enabled == "" {
		return nil, nil
	}
	if enabled != "on" || service != review.ServiceRadarr {
		return nil, fmt.Errorf("runtime policy override is invalid")
	}
	minutes, err := strconv.ParseFloat(maximumMinutes, 64)
	if err != nil || minutes <= 0 {
		return nil, fmt.Errorf("maximum runtime difference is invalid")
	}
	milliseconds := int64(minutes * float64(time.Minute/time.Millisecond))
	if float64(milliseconds) != minutes*float64(time.Minute/time.Millisecond) ||
		milliseconds > reconsideration.MaximumRuntimeDifferenceLimitMS {
		return nil, fmt.Errorf("maximum runtime difference is invalid")
	}
	return &reconsideration.PolicyOverrides{MaximumRuntimeDifferenceMS: milliseconds}, nil
}

func (app *applicationHandler) requestOriginAllowed(request *http.Request) bool {
	fetchSite := request.Header.Get("Sec-Fetch-Site")
	if fetchSite != "" && fetchSite != "same-origin" {
		return false
	}
	origin := request.Header.Get("Origin")
	if origin == "" || origin == "null" {
		return fetchSite == "same-origin"
	}
	_, allowed := app.allowedOrigins[origin]
	return allowed
}

func (app *applicationHandler) setCSRFCookie(writer http.ResponseWriter) {
	http.SetCookie(writer, &http.Cookie{
		Name: csrfCookieName, Value: app.csrfToken, Path: "/", Secure: true,
		HttpOnly: true, SameSite: http.SameSiteStrictMode,
	})
}

func sameToken(left, right string) bool {
	return len(left) == len(right) &&
		subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

func (app *applicationHandler) readSnapshots() (map[review.Service]review.Snapshot, []sourceStatus) {
	snapshots := make(map[review.Service]review.Snapshot, len(app.sources))
	statuses := make([]sourceStatus, 0, len(app.sources))
	for _, source := range app.sources {
		snapshot, found, err := source.store.Read()
		status := sourceStatus{Service: source.service, Available: found && err == nil}
		if err != nil {
			status.Error = err.Error()
		} else if found {
			generatedAt := snapshot.GeneratedAt
			status.GeneratedAt = &generatedAt
			status.Current = len(snapshot.Current)
			status.History = len(snapshot.History)
			snapshots[source.service] = snapshot
		}
		statuses = append(statuses, status)
	}
	return snapshots, statuses
}

func currentItems(
	sources []source,
	snapshots map[review.Service]review.Snapshot,
	service review.Service,
) []itemView {
	items := make([]itemView, 0)
	for _, source := range sources {
		if service != "" && source.service != service {
			continue
		}
		for _, item := range snapshots[source.service].Current {
			items = append(items, itemView{
				Item: item, Service: source.service, QueueURL: source.queueURL, Current: true,
				CanReconsider: canReconsider(item),
				CanRemove:     canRemove(item),
			})
		}
	}
	sort.Slice(items, func(left, right int) bool {
		if items[left].Service != items[right].Service {
			return items[left].Service < items[right].Service
		}
		return items[left].Item.QueueID < items[right].Item.QueueID
	})
	return items
}

func historyItems(
	sources []source,
	snapshots map[review.Service]review.Snapshot,
) []itemView {
	items := make([]itemView, 0)
	for _, source := range sources {
		for _, item := range snapshots[source.service].History {
			items = append(items, itemView{Item: item, Service: source.service, QueueURL: source.queueURL})
		}
	}
	sort.Slice(items, func(left, right int) bool {
		leftAt := items[left].Item.NoLongerQueuedAt
		rightAt := items[right].Item.NoLongerQueuedAt
		return leftAt != nil && rightAt != nil && leftAt.After(*rightAt)
	})
	return items
}

func findCase(
	sources []source,
	snapshots map[review.Service]review.Snapshot,
	caseID string,
) (itemView, bool) {
	for _, source := range sources {
		snapshot := snapshots[source.service]
		for _, current := range snapshot.Current {
			if current.CaseID == caseID {
				return itemView{
					Item: current, Service: source.service, QueueURL: source.queueURL,
					Current: true, CanReconsider: canReconsider(current),
					CanRemove: canRemove(current),
				}, true
			}
		}
		for _, historical := range snapshot.History {
			if historical.CaseID == caseID {
				return itemView{Item: historical, Service: source.service, QueueURL: source.queueURL}, true
			}
		}
	}
	return itemView{}, false
}

func (app *applicationHandler) withLatestQueueRemoval(item itemView) (itemView, error) {
	var actions *queueaction.Store
	for _, source := range app.sources {
		if source.service == item.Service {
			actions = source.actions
			break
		}
	}
	if actions == nil {
		return itemView{}, fmt.Errorf("operator action source for %q is missing", item.Service)
	}
	request, found, err := actions.Latest(item.Item.CaseID)
	if err != nil {
		return itemView{}, fmt.Errorf("read latest queue removal request: %w", err)
	}
	if !found || (item.Item.QueueRemoval != nil &&
		item.Item.QueueRemoval.RequestID == request.RequestID) {
		return item, nil
	}
	item.Item.QueueRemoval = &review.QueueRemoval{
		RequestID: request.RequestID, CreatedAt: request.CreatedAt,
	}
	item.CanRemove = false
	item.CanReconsider = false
	item.RemovalQueued = true
	return item, nil
}

func findCurrentCase(
	sources []source,
	snapshots map[review.Service]review.Snapshot,
	caseID string,
) (review.Item, source, bool) {
	for _, source := range sources {
		for _, current := range snapshots[source.service].Current {
			if current.CaseID == caseID {
				return current, source, true
			}
		}
	}
	return review.Item{}, source{}, false
}

func (app *applicationHandler) withLatestReconsideration(item itemView) (itemView, error) {
	var requests *reconsideration.Store
	for _, source := range app.sources {
		if source.service == item.Service {
			requests = source.requests
			break
		}
	}
	if requests == nil {
		return itemView{}, fmt.Errorf("reconsideration source for %q is missing", item.Service)
	}
	request, found, err := requests.Latest(item.Item.CaseID)
	if err != nil {
		return itemView{}, fmt.Errorf("read latest reconsideration request: %w", err)
	}
	if !found || (item.Item.Reconsideration != nil &&
		item.Item.Reconsideration.RequestID == request.RequestID) {
		return item, nil
	}
	if item.Item.Decision == nil {
		return itemView{}, fmt.Errorf("reconsideration request has no prior decision")
	}
	item.Item.Reconsideration = &review.Reconsideration{
		RequestID: request.RequestID, Guidance: request.Guidance,
		PolicyOverrides: request.PolicyOverrides, CreatedAt: request.CreatedAt,
		State: review.ReconsiderationPending, PriorDecision: *item.Item.Decision,
	}
	item.CanReconsider = false
	item.ReconsiderationQueued = true
	return item, nil
}

func reconsiderationPending(requests *reconsideration.Store, item review.Item) (bool, error) {
	request, found, err := requests.Latest(item.CaseID)
	if err != nil || !found {
		return false, err
	}
	return item.Reconsideration == nil || item.Reconsideration.RequestID != request.RequestID ||
		item.Reconsideration.State != review.ReconsiderationDecided, nil
}

func canReconsider(item review.Item) bool {
	return item.CaseID != "" && item.Decision != nil && item.QueueRemoval == nil &&
		(item.Reconsideration == nil ||
			item.Reconsideration.State == review.ReconsiderationDecided)
}

func canRemove(item review.Item) bool {
	return item.CaseID != "" && item.QueueIdentity != nil &&
		(item.QueueRemoval == nil || item.QueueRemoval.State == queueaction.StateFailed)
}

func (app *applicationHandler) styleHandler(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		writer.Header().Set("Allow", "GET, HEAD")
		http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writer.Header().Set("Content-Type", "text/css; charset=utf-8")
	writer.Header().Set("Cache-Control", "public, max-age=3600")
	if request.Method == http.MethodGet {
		_, _ = writer.Write(app.style)
	}
}

func (*applicationHandler) readyHandler(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writer.Header().Set("Allow", "GET")
		http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = writer.Write([]byte("ready\n"))
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		writer.Header().Set("Referrer-Policy", "no-referrer")
		writer.Header().Set("X-Content-Type-Options", "nosniff")
		writer.Header().Set("X-Frame-Options", "DENY")
		next.ServeHTTP(writer, request)
	})
}

func stateLabel(state review.State) string {
	switch state {
	case review.StateActive:
		return "Active"
	case review.StateNotProcessed:
		return "Not processed"
	case review.StatePlanningDeferred:
		return "Planning deferred"
	case review.StatePlanningFailed:
		return "Planning failed"
	case review.StateReviewed:
		return "Reviewed"
	case review.StateRepairPlanned:
		return "Repair planned"
	case review.StateExecutionBlocked:
		return "Execution blocked"
	case review.StateExecutionFailed:
		return "Execution failed"
	case review.StateNoLongerQueued:
		return "No longer queued"
	default:
		return string(state)
	}
}

package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/queueaction"
	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
	"github.com/booxter/nix-config/media-repair/internal/review"
	"github.com/booxter/nix-config/media-repair/internal/wake"
)

func TestReadyAndSecurityHeaders(t *testing.T) {
	t.Parallel()
	lidarr := reviewDirectory(t, review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceLidarr,
		GeneratedAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC), Current: []review.Item{},
	})
	radarr := reviewDirectory(t, review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceRadarr,
		GeneratedAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC), Current: []review.Item{},
	})
	handler, err := newHandler(handlerConfig(t, lidarr, radarr))
	if err != nil {
		t.Fatal(err)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/-/ready", nil))
	if response.Code != http.StatusOK || response.Header().Get("Content-Security-Policy") == "" {
		t.Fatalf("response = %#v", response.Result())
	}
}

func TestHandlerSubmitsReconsiderationForCurrentCase(t *testing.T) {
	t.Parallel()
	caseID := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	lidarr := reviewDirectory(t, review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceLidarr,
		GeneratedAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC), Current: []review.Item{},
	})
	radarr := reviewDirectory(t, review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceRadarr,
		GeneratedAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC),
		Current:     []review.Item{questionableItem(caseID)},
	})
	configuration := handlerConfig(t, lidarr, radarr)
	configuration.AllowedOrigins = []string{"https://repairr"}
	handler, err := newHandler(configuration)
	if err != nil {
		t.Fatal(err)
	}
	page := httptest.NewRecorder()
	handler.ServeHTTP(page, httptest.NewRequest(http.MethodGet, "/cases/"+caseID, nil))
	cookies := page.Result().Cookies()
	if page.Code != http.StatusOK || len(cookies) != 1 {
		t.Fatalf("GET status=%d cookies=%v", page.Code, cookies)
	}
	values := url.Values{
		"csrf_token":                         {cookies[0].Value},
		"guidance":                           {"Check the selected release."},
		"override_runtime_difference":        {"on"},
		"maximum_runtime_difference_minutes": {"30"},
	}
	store, err := reconsideration.NewStore(
		configuration.RadarrRequests, reconsideration.ServiceRadarr,
	)
	if err != nil {
		t.Fatal(err)
	}
	invalid := url.Values{
		"csrf_token":                         {cookies[0].Value},
		"guidance":                           {"Check the selected release."},
		"override_runtime_difference":        {"on"},
		"maximum_runtime_difference_minutes": {"60.5"},
	}
	request := httptest.NewRequest(
		http.MethodPost, "/cases/"+caseID+"/reconsider", strings.NewReader(invalid.Encode()),
	)
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Origin", "https://repairr")
	request.AddCookie(cookies[0])
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnprocessableEntity {
		t.Fatalf("invalid POST status=%d body=%s", response.Code, response.Body.String())
	}
	if _, found, err := store.Latest(caseID); err != nil || found {
		t.Fatalf("invalid request stored: found=%t error=%v", found, err)
	}

	request = httptest.NewRequest(
		http.MethodPost, "/cases/"+caseID+"/reconsider", strings.NewReader(values.Encode()),
	)
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Origin", "https://repairr")
	request.AddCookie(cookies[0])
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusSeeOther {
		t.Fatalf("POST status=%d body=%s", response.Code, response.Body.String())
	}
	submitted, found, err := store.Latest(caseID)
	if err != nil || !found || submitted.Guidance != values.Get("guidance") ||
		submitted.PolicyOverrides == nil ||
		submitted.PolicyOverrides.MaximumRuntimeDifferenceMS != 30*60*1_000 {
		t.Fatalf("request=%#v found=%v err=%v", submitted, found, err)
	}
	assertWakeMarker(t, configuration.RadarrTrigger)

	request = httptest.NewRequest(
		http.MethodPost, "/cases/"+caseID+"/reconsider", strings.NewReader(values.Encode()),
	)
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Origin", "https://repairr")
	request.AddCookie(cookies[0])
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusConflict {
		t.Fatalf("second POST status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestHandlerRejectsCrossOriginReconsideration(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		origin    string
		fetchSite string
	}{
		{name: "unknown origin", origin: "https://attacker.example", fetchSite: "same-origin"},
		{name: "cross-site request", origin: "null", fetchSite: "cross-site"},
		{name: "missing metadata"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			caseID := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
			now := time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC)
			lidarr := reviewDirectory(t, review.Snapshot{
				Version: review.SnapshotVersion, Service: review.ServiceLidarr,
				GeneratedAt: now, Current: []review.Item{},
			})
			radarr := reviewDirectory(t, review.Snapshot{
				Version: review.SnapshotVersion, Service: review.ServiceRadarr,
				GeneratedAt: now, Current: []review.Item{questionableItem(caseID)},
			})
			configuration := handlerConfig(t, lidarr, radarr)
			handler, err := newHandler(configuration)
			if err != nil {
				t.Fatal(err)
			}
			page := httptest.NewRecorder()
			handler.ServeHTTP(page, httptest.NewRequest(http.MethodGet, "/cases/"+caseID, nil))
			cookies := page.Result().Cookies()
			if len(cookies) != 1 {
				t.Fatalf("cookies = %v", cookies)
			}
			values := url.Values{
				"csrf_token": {cookies[0].Value},
				"guidance":   {"Do not accept this request."},
			}
			request := httptest.NewRequest(
				http.MethodPost,
				"/cases/"+caseID+"/reconsider",
				strings.NewReader(values.Encode()),
			)
			request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			request.Header.Set("Origin", test.origin)
			request.Header.Set("Sec-Fetch-Site", test.fetchSite)
			request.AddCookie(cookies[0])
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != http.StatusForbidden {
				t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
			}
			store, err := reconsideration.NewStore(
				configuration.RadarrRequests,
				reconsideration.ServiceRadarr,
			)
			if err != nil {
				t.Fatal(err)
			}
			if _, found, err := store.Latest(caseID); err != nil || found {
				t.Fatalf("request stored: found=%t error=%v", found, err)
			}
		})
	}
}

func TestHandlerConfirmsAndRequestsCurrentQueueRemoval(t *testing.T) {
	t.Parallel()
	caseID := "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
	now := time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC)
	lidarr := reviewDirectory(t, review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceLidarr,
		GeneratedAt: now, Current: []review.Item{},
	})
	radarr := reviewDirectory(t, review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceRadarr,
		GeneratedAt: now, Current: []review.Item{questionableItem(caseID)},
	})
	configuration := handlerConfig(t, lidarr, radarr)
	configuration.AllowedOrigins = []string{"https://repairr"}
	handler, err := newHandler(configuration)
	if err != nil {
		t.Fatal(err)
	}
	confirmation := httptest.NewRecorder()
	handler.ServeHTTP(
		confirmation,
		httptest.NewRequest(http.MethodGet, "/cases/"+caseID+"/remove", nil),
	)
	cookies := confirmation.Result().Cookies()
	if confirmation.Code != http.StatusOK || len(cookies) != 1 {
		t.Fatalf("confirmation status=%d cookies=%v", confirmation.Code, cookies)
	}
	values := url.Values{"csrf_token": {cookies[0].Value}}
	request := httptest.NewRequest(
		http.MethodPost, "/cases/"+caseID+"/remove", strings.NewReader(values.Encode()),
	)
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Origin", "https://repairr")
	request.AddCookie(cookies[0])
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusSeeOther {
		t.Fatalf("POST status=%d body=%s", response.Code, response.Body.String())
	}
	store, err := queueaction.NewStore(configuration.RadarrActions, queueaction.ServiceRadarr)
	if err != nil {
		t.Fatal(err)
	}
	stored, found, err := store.Latest(caseID)
	wanted := questionableItem(caseID).QueueIdentity
	if err != nil || !found || stored.Action != queueaction.ActionRemoveTracking ||
		wanted == nil || stored.Queue != *wanted {
		t.Fatalf("request=%#v found=%t err=%v", stored, found, err)
	}
	assertWakeMarker(t, configuration.RadarrTrigger)
}

func questionableItem(caseID string) review.Item {
	identity := queueaction.QueueIdentity{
		QueueID: 1, DownloadID: "download", SubjectID: 42,
		Status: "completed", TrackedDownloadStatus: "warning",
	}
	return review.Item{
		QueueID: 1, Title: "Artist - Album", QueueStatus: "completed",
		TrackedStatus: "warning", State: review.StateReviewed, CaseID: caseID,
		LastSeenAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC),
		Decision: &review.Decision{
			Action: "no_repair", Reason: "incomplete_release",
			Explanation: "The release appears incomplete.", EvidenceRefs: []string{},
		},
		QueueIdentity: &identity,
	}
}

func handlerConfig(t *testing.T, lidarr, radarr string) config {
	t.Helper()
	lidarrRequests := filepath.Join(t.TempDir(), "lidarr-requests")
	radarrRequests := filepath.Join(t.TempDir(), "radarr-requests")
	lidarrActions := filepath.Join(t.TempDir(), "lidarr-actions")
	radarrActions := filepath.Join(t.TempDir(), "radarr-actions")
	lidarrTrigger := filepath.Join(t.TempDir(), "lidarr-trigger")
	radarrTrigger := filepath.Join(t.TempDir(), "radarr-trigger")
	for _, directory := range []string{
		lidarrRequests, radarrRequests, lidarrActions, radarrActions,
		lidarrTrigger, radarrTrigger,
	} {
		if err := os.Mkdir(directory, 0o750); err != nil {
			t.Fatal(err)
		}
	}
	return config{
		LidarrSnapshot: lidarr, RadarrSnapshot: radarr,
		LidarrRequests: lidarrRequests, RadarrRequests: radarrRequests,
		LidarrActions: lidarrActions, RadarrActions: radarrActions,
		LidarrTrigger: lidarrTrigger, RadarrTrigger: radarrTrigger,
		LidarrURL: "https://lidarr.example/activity/queue",
		RadarrURL: "https://radarr.example/activity/queue",
		PublicURL: "https://repairr.example",
	}
}

func assertWakeMarker(t *testing.T, directory string) {
	t.Helper()
	info, err := os.Stat(filepath.Join(directory, wake.FileName))
	if err != nil || !info.Mode().IsRegular() {
		t.Fatalf("wake marker = %#v, error = %v", info, err)
	}
}

func reviewDirectory(t *testing.T, snapshot review.Snapshot) string {
	t.Helper()
	directory := filepath.Join(t.TempDir(), string(snapshot.Service))
	if err := os.Mkdir(directory, 0o750); err != nil {
		t.Fatal(err)
	}
	store, err := review.NewStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Publish(snapshot); err != nil {
		t.Fatal(err)
	}
	return directory
}

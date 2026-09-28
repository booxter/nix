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

	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
	"github.com/booxter/nix-config/media-repair/internal/review"
)

func TestHandlerRendersEscapedDecisionAndCasePage(t *testing.T) {
	t.Parallel()
	lidarr := reviewDirectory(t, review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceLidarr,
		GeneratedAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC),
		Current: []review.Item{{
			QueueID: 1, Title: "Release <script>alert(1)</script>", Subject: "Artist — Album",
			QueueStatus: "completed", TrackedStatus: "warning", State: review.StateReviewed,
			CaseID:     "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			LastSeenAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC),
			Decision: &review.Decision{
				Action: "no_repair", Reason: "incomplete_release",
				Explanation: "Missing <b>track</b>.", EvidenceRefs: []string{"artifact:one"},
			},
		}},
	})
	radarr := reviewDirectory(t, review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceRadarr,
		GeneratedAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC), Current: []review.Item{},
	})
	handler, err := newHandler(handlerConfig(t, lidarr, radarr))
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "/lidarr", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	body := response.Body.String()
	if response.Code != http.StatusOK || strings.Contains(body, "<script>") ||
		!strings.Contains(body, "&lt;script&gt;") || !strings.Contains(body, "incomplete_release") {
		t.Fatalf("status=%d body=%s", response.Code, body)
	}
	request = httptest.NewRequest(
		http.MethodGet,
		"/cases/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		nil,
	)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	body = response.Body.String()
	if response.Code != http.StatusOK || !strings.Contains(body, "Missing &lt;b&gt;track&lt;/b&gt;.") ||
		!strings.Contains(body, "artifact:one") {
		t.Fatalf("status=%d body=%s", response.Code, body)
	}
}

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
		GeneratedAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC),
		Current:     []review.Item{questionableItem(caseID)},
	})
	radarr := reviewDirectory(t, review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceRadarr,
		GeneratedAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC), Current: []review.Item{},
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
		"csrf_token": {cookies[0].Value},
		"guidance":   {"Check whether the disc numbering supports the selected release."},
	}
	request := httptest.NewRequest(
		http.MethodPost, "/cases/"+caseID+"/reconsider", strings.NewReader(values.Encode()),
	)
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Origin", "https://repairr")
	request.AddCookie(cookies[0])
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusSeeOther {
		t.Fatalf("POST status=%d body=%s", response.Code, response.Body.String())
	}
	store, err := reconsideration.NewStore(
		configuration.LidarrRequests, reconsideration.ServiceLidarr,
	)
	if err != nil {
		t.Fatal(err)
	}
	submitted, found, err := store.Latest(caseID)
	if err != nil || !found || submitted.Guidance != values.Get("guidance") {
		t.Fatalf("request=%#v found=%v err=%v", submitted, found, err)
	}
}

func TestHandlerRejectsUnknownOrigin(t *testing.T) {
	t.Parallel()
	caseID := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	lidarr := reviewDirectory(t, review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceLidarr,
		GeneratedAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC),
		Current:     []review.Item{questionableItem(caseID)},
	})
	radarr := reviewDirectory(t, review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceRadarr,
		GeneratedAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC), Current: []review.Item{},
	})
	configuration := handlerConfig(t, lidarr, radarr)
	configuration.AllowedOrigins = []string{"https://repairr"}
	handler, err := newHandler(configuration)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(
		http.MethodPost, "/cases/"+caseID+"/reconsider", nil,
	)
	request.Header.Set("Origin", "https://attacker.example")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("POST status=%d body=%s", response.Code, response.Body.String())
	}
}

func questionableItem(caseID string) review.Item {
	return review.Item{
		QueueID: 1, Title: "Artist - Album", QueueStatus: "completed",
		TrackedStatus: "warning", State: review.StateReviewed, CaseID: caseID,
		LastSeenAt: time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC),
		Decision: &review.Decision{
			Action: "no_repair", Reason: "incomplete_release",
			Explanation: "The release appears incomplete.", EvidenceRefs: []string{},
		},
	}
}

func handlerConfig(t *testing.T, lidarr, radarr string) config {
	t.Helper()
	lidarrRequests := filepath.Join(t.TempDir(), "lidarr-requests")
	radarrRequests := filepath.Join(t.TempDir(), "radarr-requests")
	for _, directory := range []string{lidarrRequests, radarrRequests} {
		if err := os.Mkdir(directory, 0o750); err != nil {
			t.Fatal(err)
		}
	}
	return config{
		LidarrSnapshot: lidarr, RadarrSnapshot: radarr,
		LidarrRequests: lidarrRequests, RadarrRequests: radarrRequests,
		LidarrURL: "https://lidarr.example/activity/queue",
		RadarrURL: "https://radarr.example/activity/queue",
		PublicURL: "https://repairr.example",
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

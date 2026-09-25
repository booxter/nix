package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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
	handler, err := newHandler(config{
		LidarrSnapshot: lidarr, RadarrSnapshot: radarr,
		LidarrURL: "https://lidarr.example/activity/queue",
		RadarrURL: "https://radarr.example/activity/queue",
	})
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
	handler, err := newHandler(config{
		LidarrSnapshot: lidarr, RadarrSnapshot: radarr,
		LidarrURL: "https://lidarr.example/activity/queue",
		RadarrURL: "https://radarr.example/activity/queue",
	})
	if err != nil {
		t.Fatal(err)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/-/ready", nil))
	if response.Code != http.StatusOK || response.Header().Get("Content-Security-Policy") == "" {
		t.Fatalf("response = %#v", response.Result())
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

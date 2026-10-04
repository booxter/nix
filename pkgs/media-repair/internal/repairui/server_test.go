package repairui

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

type fixture struct {
	store   *jobs.Store
	handler http.Handler
	job     jobs.Job
	wakes   []jobs.Service
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	store, err := jobs.Open(filepath.Join(t.TempDir(), "jobs.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })

	job, err := store.Observe(context.Background(), jobs.Job{
		Service:    jobs.Lidarr,
		QueueID:    42,
		DownloadID: "album",
		Title:      "Album <script>alert(1)</script>",
		UpdatedAt:  time.Now().UTC(),
	})
	if err != nil {
		t.Fatal(err)
	}

	fixture := &fixture{store: store, job: job}
	fixture.handler, err = New(Config{
		Store:   store,
		Origins: []string{"https://repairr.home.arpa"},
		Wake: func(service jobs.Service) {
			fixture.wakes = append(fixture.wakes, service)
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return fixture
}

func (fixture *fixture) get(path string) *httptest.ResponseRecorder {
	response := httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
	return response
}

func (fixture *fixture) removalRequest(t *testing.T) *http.Request {
	t.Helper()
	page := fixture.get(fmt.Sprintf("/jobs/%d/remove", fixture.job.ID))
	if page.Code != http.StatusOK {
		t.Fatalf("confirmation: %d %s", page.Code, page.Body.String())
	}
	cookies := page.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("cookies: %v", cookies)
	}

	form := url.Values{"csrf_token": {cookies[0].Value}}
	request := httptest.NewRequest(http.MethodPost,
		fmt.Sprintf("/jobs/%d/remove", fixture.job.ID), strings.NewReader(form.Encode()))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Origin", "https://repairr.home.arpa")
	request.AddCookie(cookies[0])
	return request
}

func TestRemovalWakesSchedulerAndLeavesCurrentListAfterCompletion(t *testing.T) {
	fixture := newFixture(t)
	response := httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, fixture.removalRequest(t))
	if response.Code != http.StatusSeeOther {
		t.Fatalf("request: %d %s", response.Code, response.Body.String())
	}
	if len(fixture.wakes) != 1 || fixture.wakes[0] != jobs.Lidarr {
		t.Fatalf("scheduler not notified: %v", fixture.wakes)
	}

	ctx := context.Background()
	job, err := fixture.store.Get(ctx, fixture.job.ID)
	if err != nil || job.PendingAction != jobs.Delete {
		t.Fatalf("request not durable: %+v %v", job, err)
	}
	job, err = fixture.store.StartRemoval(ctx, job.ID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := fixture.store.FinishRemoval(ctx, job, nil, time.Now()); err != nil {
		t.Fatal(err)
	}

	current := fixture.get("/lidarr")
	history := fixture.get("/history")
	if current.Code != http.StatusOK || strings.Contains(current.Body.String(), "Album") {
		t.Fatalf("removed item remains current: %s", current.Body.String())
	}
	if history.Code != http.StatusOK || !strings.Contains(history.Body.String(), "Album") {
		t.Fatalf("removed item missing from history: %s", history.Body.String())
	}
}

func TestRemovalRejectsCrossSiteAndMissingToken(t *testing.T) {
	for _, scenario := range []string{"foreign origin", "missing cookie", "cross-site fetch"} {
		t.Run(scenario, func(t *testing.T) {
			fixture := newFixture(t)
			request := fixture.removalRequest(t)
			switch scenario {
			case "foreign origin":
				request.Header.Set("Origin", "https://attacker.invalid")
			case "missing cookie":
				request.Header.Del("Cookie")
			case "cross-site fetch":
				request.Header.Set("Sec-Fetch-Site", "cross-site")
			}

			response := httptest.NewRecorder()
			fixture.handler.ServeHTTP(response, request)
			if response.Code != http.StatusForbidden || len(fixture.wakes) != 0 {
				t.Fatalf("unsafe request accepted: %d, wakes=%v", response.Code, fixture.wakes)
			}
		})
	}
}

func TestTitlesAreEscaped(t *testing.T) {
	fixture := newFixture(t)
	for _, path := range []string{"/lidarr", fmt.Sprintf("/jobs/%d", fixture.job.ID)} {
		response := fixture.get(path)
		if response.Code != http.StatusOK || strings.Contains(response.Body.String(), "<script>") ||
			!strings.Contains(response.Body.String(), "&lt;script&gt;") {
			t.Fatalf("unsafe title at %s: %s", path, response.Body.String())
		}
	}
}

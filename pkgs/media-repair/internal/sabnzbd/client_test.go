package sabnzbd

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

const testDownloadID = "998d2f1f-cb49-4714-be1e-875f03e1f3c2"

func TestFindDownloadMapsCompletedHistoryRecord(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		query := request.URL.Query()
		if request.Method != http.MethodGet || request.URL.Path != "/api" ||
			query.Get("mode") != "history" || query.Get("nzo_ids") != testDownloadID ||
			query.Get("start") != "0" || query.Get("limit") != "2" ||
			query.Get("output") != "json" || query.Get("apikey") != "test-key" {
			http.Error(writer, "invalid request", http.StatusBadRequest)
			return
		}
		fixture, err := os.ReadFile(filepath.Join("testdata", "history.json"))
		if err != nil {
			t.Error(err)
			http.Error(writer, "fixture unavailable", http.StatusInternalServerError)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write(fixture)
	}))
	defer server.Close()
	client, err := New(server.URL+"/api", "test-key", time.Second, server.Client())
	if err != nil {
		t.Fatal(err)
	}

	download, found, err := client.FindDownload(context.Background(), testDownloadID)
	if err != nil {
		t.Fatal(err)
	}
	if !found || download.Client != controller.DownloadClientSABnzbd ||
		download.SourceType != controller.DownloadSourceUsenet ||
		download.ID != testDownloadID || download.IDComparison != controller.DownloadIDExact ||
		!download.Stable || !download.Complete ||
		download.Name != "duplicate.the.death.of.robin.hood.2026.1080p.bluray.h264" ||
		download.OutputPath != "/data/media/usenet/manual/duplicate.the.death.of.robin.hood.2026.1080p.bluray.h264" ||
		download.TotalSizeBytes != 34265436989 ||
		download.ContentOwnership != controller.DownloadContentOutputTree ||
		!reflect.DeepEqual(download.Labels, []string{"movies"}) || len(download.Files) != 0 {
		t.Fatalf("download = %#v", download)
	}
	if download.AddedAt == nil || download.CompletedAt == nil ||
		!download.AddedAt.Equal(time.Unix(1788549636, 0)) ||
		!download.CompletedAt.Equal(time.Unix(1788552041, 0)) {
		t.Fatalf("download times = %v, %v", download.AddedAt, download.CompletedAt)
	}
}

func TestFindDownloadReturnsNotFound(t *testing.T) {
	t.Parallel()

	client, server := testClient(t, `{"history":{"slots":[]}}`)
	defer server.Close()
	_, found, err := client.FindDownload(context.Background(), testDownloadID)
	if err != nil || found {
		t.Fatalf("found = %v, error = %v", found, err)
	}
}

func TestFindDownloadRejectsAmbiguousOrMismatchedHistory(t *testing.T) {
	t.Parallel()

	fixture, err := os.ReadFile(filepath.Join("testdata", "history.json"))
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name string
		body string
		want string
	}{
		{name: "missing history", body: `{}`, want: "incomplete"},
		{name: "null slots", body: `{"history":{"slots":null}}`, want: "incomplete"},
		{
			name: "different ID",
			body: strings.Replace(string(fixture), testDownloadID, "other-id", 1),
			want: "different download ID",
		},
		{
			name: "multiple",
			body: `{"history":{"slots":[{},{}]}}`,
			want: "2 history records",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			client, server := testClient(t, test.body)
			defer server.Close()
			_, _, err := client.FindDownload(context.Background(), testDownloadID)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want containing %q", err, test.want)
			}
		})
	}
}

func TestNewRejectsUnsafeConfiguration(t *testing.T) {
	t.Parallel()

	tests := []struct {
		endpoint string
		key      string
		timeout  time.Duration
		client   *http.Client
	}{
		{endpoint: "http://sabnzbd.example/api", key: "key", timeout: time.Second, client: http.DefaultClient},
		{endpoint: "/api", key: "key", timeout: time.Second, client: http.DefaultClient},
		{endpoint: "http://127.0.0.1/api?key=secret", key: "key", timeout: time.Second, client: http.DefaultClient},
		{endpoint: "http://127.0.0.1/api", key: "", timeout: time.Second, client: http.DefaultClient},
		{endpoint: "http://127.0.0.1/api", key: "key", client: http.DefaultClient},
		{endpoint: "http://127.0.0.1/api", key: "key", timeout: time.Second},
	}
	for _, test := range tests {
		if _, err := New(test.endpoint, test.key, test.timeout, test.client); err == nil {
			t.Fatalf("configuration was accepted: %#v", test)
		}
	}
}

func TestFindDownloadDoesNotExposeKeyInTransportErrors(t *testing.T) {
	t.Parallel()

	client, err := New(
		"http://127.0.0.1/api", "do-not-expose-key", time.Second,
		&http.Client{Transport: failingTransport{}},
	)
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = client.FindDownload(context.Background(), testDownloadID)
	if err == nil || strings.Contains(err.Error(), "do-not-expose-key") ||
		strings.Contains(err.Error(), "transport-secret") {
		t.Fatalf("error = %v", err)
	}
}

type failingTransport struct{}

func (failingTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("transport-secret")
}

func testClient(t *testing.T, body string) (*Client, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(body))
	}))
	client, err := New(server.URL, "test-key", time.Second, server.Client())
	if err != nil {
		server.Close()
		t.Fatal(err)
	}
	return client, server
}

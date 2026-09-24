package transmission

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

const (
	testDownloadID = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
	testSessionID  = "transmission-session-token"
)

func TestFindDownload(t *testing.T) {
	t.Parallel()

	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests++
		assertTorrentRequest(t, request, requests)
		if requests == 1 {
			writer.Header().Set(sessionIDHeader, testSessionID)
			writer.WriteHeader(http.StatusConflict)
			return
		}
		fixture, err := os.ReadFile(filepath.Join("testdata", "torrent-get.json"))
		if err != nil {
			t.Error(err)
			http.Error(writer, "fixture unavailable", http.StatusInternalServerError)
			return
		}
		writer.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = writer.Write(fixture)
	}))
	defer server.Close()
	client, err := New(server.URL+"/transmission/rpc", time.Second, server.Client())
	if err != nil {
		t.Fatal(err)
	}

	torrent, found, err := client.FindDownload(context.Background(), testDownloadID)
	if err != nil {
		t.Fatal(err)
	}
	if !found || requests != 2 {
		t.Fatalf("found = %v, requests = %d", found, requests)
	}
	if torrent.ID != "abcdef0123456789abcdef0123456789abcdef01" ||
		torrent.IDComparison != controller.DownloadIDASCIIInsensitive ||
		torrent.Client != controller.DownloadClientTransmission ||
		torrent.SourceType != controller.DownloadSourceTorrent ||
		torrent.Name != "Example.Movie.2026.1080p.BluRay-GROUP" ||
		!torrent.Stable || !torrent.Complete ||
		torrent.OutputPath != "/downloads/Example.Movie.2026.1080p.BluRay-GROUP" ||
		torrent.TotalSizeBytes != 3_900_000_000 ||
		!reflect.DeepEqual(torrent.Labels, []string{"radarr", "movies"}) {
		t.Fatalf("torrent = %#v", torrent)
	}
	if torrent.CreatedAt == nil || torrent.AddedAt == nil || torrent.CompletedAt == nil ||
		!torrent.CreatedAt.Equal(time.Unix(1_788_600_000, 0)) ||
		!torrent.AddedAt.Equal(time.Unix(1_788_703_200, 0)) ||
		!torrent.CompletedAt.Equal(time.Unix(1_788_706_800, 0)) {
		t.Fatalf("torrent times = %v, %v, %v", torrent.CreatedAt, torrent.AddedAt, torrent.CompletedAt)
	}
	if len(torrent.Files) != 2 || torrent.Files[0].Index != 0 || !torrent.Files[0].HasIndex ||
		torrent.Files[0].Path != "/downloads/Example.Movie.2026/Example.Movie.2026.CD1.mkv" ||
		torrent.Files[0].LengthBytes != 2_000_000_000 ||
		torrent.Files[0].BytesCompleted != 2_000_000_000 || !torrent.Files[0].Selected ||
		torrent.Files[1].Index != 1 || !torrent.Files[1].HasIndex {
		t.Fatalf("files = %#v", torrent.Files)
	}
}

func TestFindDownloadReturnsNotFound(t *testing.T) {
	t.Parallel()

	client, server := testClient(t, map[string]any{"torrents": []any{}})
	defer server.Close()
	_, found, err := client.FindDownload(context.Background(), testDownloadID)
	if err != nil || found {
		t.Fatalf("found = %v, error = %v", found, err)
	}
}

func TestFindDownloadRejectsInvalidID(t *testing.T) {
	t.Parallel()

	client, err := New("http://127.0.0.1/transmission/rpc", time.Second, http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := client.FindDownload(context.Background(), " invalid "); err == nil {
		t.Fatal("invalid ID was accepted")
	}
}

func TestNewRejectsInvalidConfiguration(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		endpoint string
		timeout  time.Duration
		client   *http.Client
	}{
		{name: "nil client", endpoint: "http://127.0.0.1/rpc", timeout: time.Second},
		{name: "zero timeout", endpoint: "http://127.0.0.1/rpc", client: http.DefaultClient},
		{name: "relative URL", endpoint: "/rpc", timeout: time.Second, client: http.DefaultClient},
		{name: "remote plaintext", endpoint: "http://transmission.example/rpc", timeout: time.Second, client: http.DefaultClient},
		{name: "credentials", endpoint: "https://user:password@transmission.example/rpc", timeout: time.Second, client: http.DefaultClient},
		{name: "query", endpoint: "https://transmission.example/rpc?token=secret", timeout: time.Second, client: http.DefaultClient},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if _, err := New(test.endpoint, test.timeout, test.client); err == nil {
				t.Fatal("invalid configuration was accepted")
			}
		})
	}
}

func TestFindDownloadRejectsInconsistentResult(t *testing.T) {
	t.Parallel()

	valid := validTorrentResponse()
	duplicate := validTorrentResponse()
	tests := []struct {
		name   string
		result any
		want   string
	}{
		{name: "missing torrents", result: map[string]any{}, want: "missing torrents"},
		{name: "multiple torrents", result: map[string]any{"torrents": []any{valid, duplicate}}, want: "2 torrents"},
		{name: "null torrent", result: map[string]any{"torrents": []any{nil}}, want: "torrent is null"},
		{
			name: "mismatched file stats",
			result: map[string]any{"torrents": []any{mergeTorrent(validTorrentResponse(), map[string]any{
				"file_stats": []any{},
			})}},
			want: "1 files and 0 file stats",
		},
		{
			name: "mismatched completion",
			result: map[string]any{"torrents": []any{mergeTorrent(validTorrentResponse(), map[string]any{
				"file_stats": []any{map[string]any{"bytes_completed": 0, "wanted": true, "priority": 0}},
			})}},
			want: "completion values disagree",
		},
		{
			name: "mismatched total",
			result: map[string]any{"torrents": []any{mergeTorrent(validTorrentResponse(), map[string]any{
				"total_size": 2,
			})}},
			want: "file sizes total 1 but torrent reports 2",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			client, server := testClient(t, test.result)
			defer server.Close()
			_, _, err := client.FindDownload(context.Background(), testDownloadID)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestFindDownloadRejectsInvalidRPCResponses(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		response string
		want     string
	}{
		{name: "malformed", response: `{"jsonrpc":`, want: "decode Transmission"},
		{name: "wrong version", response: `{"jsonrpc":"1.0","id":1,"result":{}}`, want: "unsupported JSON-RPC"},
		{name: "wrong ID", response: `{"jsonrpc":"2.0","id":2,"result":{}}`, want: "mismatched JSON-RPC"},
		{name: "missing result", response: `{"jsonrpc":"2.0","id":1}`, want: "has no result"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
				writer.Header().Set("Content-Type", "application/json")
				_, _ = writer.Write([]byte(test.response))
			}))
			defer server.Close()
			client, err := New(server.URL, time.Second, server.Client())
			if err != nil {
				t.Fatal(err)
			}
			_, _, err = client.FindDownload(context.Background(), testDownloadID)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestFindDownloadSanitizesErrors(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		statusCode int
		response   string
		wantHTTP   int
		wantRPC    int
	}{
		{name: "HTTP", statusCode: http.StatusInternalServerError, response: "secret response", wantHTTP: 500},
		{name: "RPC", statusCode: http.StatusOK, response: `{"jsonrpc":"2.0","id":1,"error":{"code":7,"message":"secret response"}}`, wantRPC: 7},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
				writer.Header().Set("Content-Type", "application/json")
				writer.WriteHeader(test.statusCode)
				_, _ = writer.Write([]byte(test.response))
			}))
			defer server.Close()
			client, err := New(server.URL, time.Second, server.Client())
			if err != nil {
				t.Fatal(err)
			}
			_, _, err = client.FindDownload(context.Background(), testDownloadID)
			if err == nil || strings.Contains(err.Error(), "secret") {
				t.Fatalf("error = %v", err)
			}
			var httpError *HTTPError
			var rpcError *RPCError
			if test.wantHTTP != 0 && (!errors.As(err, &httpError) || httpError.StatusCode != test.wantHTTP) {
				t.Fatalf("HTTP error = %#v", httpError)
			}
			if test.wantRPC != 0 && (!errors.As(err, &rpcError) || rpcError.Code != test.wantRPC) {
				t.Fatalf("RPC error = %#v", rpcError)
			}
		})
	}
}

func TestFindDownloadRejectsOversizedResponse(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		writer.Header().Set("Content-Length", strconv.Itoa(maximumResponseBytes+1))
		_, _ = writer.Write([]byte("{}"))
	}))
	defer server.Close()
	client, err := New(server.URL, time.Second, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = client.FindDownload(context.Background(), testDownloadID)
	if !errors.Is(err, errResponseTooLarge) {
		t.Fatalf("error = %v", err)
	}
}

func TestFindDownloadTimesOut(t *testing.T) {
	t.Parallel()

	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		<-release
	}))
	defer server.Close()
	client, err := New(server.URL, 20*time.Millisecond, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = client.FindDownload(context.Background(), testDownloadID)
	close(release)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error = %v", err)
	}
}

func assertTorrentRequest(t *testing.T, request *http.Request, attempt int) {
	t.Helper()
	if request.Method != http.MethodPost || request.URL.Path != "/transmission/rpc" {
		t.Errorf("request = %s %s", request.Method, request.URL.Path)
	}
	if request.Header.Get("Content-Type") != "application/json" ||
		request.Header.Get("Accept") != "application/json" {
		t.Errorf("content headers = %#v", request.Header)
	}
	wantSessionID := ""
	if attempt == 2 {
		wantSessionID = testSessionID
	}
	if sessionID := request.Header.Get(sessionIDHeader); sessionID != wantSessionID {
		t.Errorf("session ID = %q, want %q", sessionID, wantSessionID)
	}
	var payload rpcRequest
	if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if payload.JSONRPC != "2.0" || payload.ID != 1 || payload.Method != "torrent_get" ||
		!reflect.DeepEqual(payload.Params.IDs, []string{testDownloadID}) ||
		!reflect.DeepEqual(payload.Params.Fields, torrentFields) {
		t.Errorf("payload = %#v", payload)
	}
}

func testClient(t *testing.T, result any) (*Client, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"jsonrpc": "2.0", "id": 1, "result": result,
		})
	}))
	client, err := New(server.URL, time.Second, server.Client())
	if err != nil {
		server.Close()
		t.Fatal(err)
	}
	return client, server
}

func validTorrentResponse() map[string]any {
	return map[string]any{
		"hash_string": "hash", "name": "Movie", "status": 6,
		"percent_done": 1.0, "left_until_done": 0, "is_finished": true,
		"download_dir": "/downloads", "labels": []any{},
		"date_created": 0, "added_date": 1, "done_date": 2, "total_size": 1,
		"files": []any{map[string]any{
			"name": "movie.mkv", "length": 1, "bytes_completed": 1,
		}},
		"file_stats": []any{map[string]any{
			"bytes_completed": 1, "wanted": true, "priority": 0,
		}},
	}
}

func mergeTorrent(base map[string]any, changes map[string]any) map[string]any {
	for key, value := range changes {
		base[key] = value
	}
	return base
}

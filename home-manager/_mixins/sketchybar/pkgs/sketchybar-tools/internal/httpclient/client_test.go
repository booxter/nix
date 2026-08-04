package httpclient

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func responseServer(t *testing.T, statusCode int, body string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(statusCode)
		if _, err := io.WriteString(response, body); err != nil {
			t.Errorf("write response: %v", err)
		}
	}))
}

func TestGetReturnsBoundedSuccessfulResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet {
			t.Errorf("request method = %s, want GET", request.Method)
		}
		if _, err := io.WriteString(response, "healthy"); err != nil {
			t.Errorf("write response: %v", err)
		}
	}))
	defer server.Close()

	body, err := Get(context.Background(), server.Client(), server.URL, 7)
	if err != nil {
		t.Fatalf("Get returned an error: %v", err)
	}
	if string(body) != "healthy" {
		t.Errorf("response = %q, want healthy", body)
	}
}

func TestGetWithHeadersAddsRequestHeaders(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if got := request.Header.Get("Accept"); got != "application/json" {
			t.Errorf("Accept header = %q, want application/json", got)
		}
		response.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	_, err := GetWithHeaders(
		context.Background(),
		server.Client(),
		server.URL,
		1024,
		http.Header{"Accept": {"application/json"}},
	)
	if err != nil {
		t.Fatalf("GetWithHeaders returned an error: %v", err)
	}
}

func TestGetRejectsHTTPFailure(t *testing.T) {
	server := responseServer(t, http.StatusServiceUnavailable, "unavailable")
	defer server.Close()

	_, err := Get(
		context.Background(),
		server.Client(),
		server.URL,
		1024,
	)
	if err == nil || !strings.Contains(err.Error(), "503 Service Unavailable") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestGetRejectsOversizedResponse(t *testing.T) {
	server := responseServer(t, http.StatusOK, "too large")
	defer server.Close()

	_, err := Get(
		context.Background(),
		server.Client(),
		server.URL,
		3,
	)
	if err == nil || !strings.Contains(err.Error(), "exceeds 3 bytes") {
		t.Fatalf("unexpected error: %v", err)
	}
}

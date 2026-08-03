package httpclient

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func responseClient(statusCode int, body string) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: statusCode,
			Status:     fmt.Sprintf("%d %s", statusCode, http.StatusText(statusCode)),
			Body:       io.NopCloser(strings.NewReader(body)),
		}, nil
	})}
}

func TestGetReturnsBoundedSuccessfulResponse(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.Method != http.MethodGet {
			t.Errorf("request method = %s, want GET", request.Method)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Status:     "200 OK",
			Body:       io.NopCloser(strings.NewReader("healthy")),
		}, nil
	})}

	body, err := Get(context.Background(), client, "https://status.test", 7)
	if err != nil {
		t.Fatalf("Get returned an error: %v", err)
	}
	if string(body) != "healthy" {
		t.Errorf("response = %q, want healthy", body)
	}
}

func TestGetWithHeadersAddsRequestHeaders(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if got := request.Header.Get("Accept"); got != "application/json" {
			t.Errorf("Accept header = %q, want application/json", got)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Status:     "200 OK",
			Body:       io.NopCloser(strings.NewReader("healthy")),
		}, nil
	})}

	_, err := GetWithHeaders(
		context.Background(),
		client,
		"https://status.test",
		1024,
		http.Header{"Accept": {"application/json"}},
	)
	if err != nil {
		t.Fatalf("GetWithHeaders returned an error: %v", err)
	}
}

func TestGetRejectsHTTPFailure(t *testing.T) {
	_, err := Get(
		context.Background(),
		responseClient(http.StatusServiceUnavailable, "unavailable"),
		"https://status.test",
		1024,
	)
	if err == nil || !strings.Contains(err.Error(), "503 Service Unavailable") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestGetRejectsOversizedResponse(t *testing.T) {
	_, err := Get(
		context.Background(),
		responseClient(http.StatusOK, "too large"),
		"https://status.test",
		3,
	)
	if err == nil || !strings.Contains(err.Error(), "exceeds 3 bytes") {
		t.Fatalf("unexpected error: %v", err)
	}
}

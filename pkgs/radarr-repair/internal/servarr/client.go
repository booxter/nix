package servarr

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"golift.io/starr"
)

const MaximumResponseBytes = 8 << 20

var ErrResponseTooLarge = fmt.Errorf("Servarr response exceeds %d bytes", MaximumResponseBytes)

type HTTPError struct {
	Service    string
	StatusCode int
}

func (err *HTTPError) Error() string {
	return fmt.Sprintf("%s returned HTTP status %d", err.Service, err.StatusCode)
}

func NewConfig(service, baseURL, apiKey string, httpClient *http.Client) (*starr.Config, error) {
	if service == "" {
		return nil, fmt.Errorf("Servarr service name is required")
	}
	if httpClient == nil {
		return nil, fmt.Errorf("%s HTTP client is required", service)
	}
	if apiKey == "" {
		return nil, fmt.Errorf("%s API key is required", service)
	}
	parsedURL, err := url.Parse(baseURL)
	if err != nil {
		return nil, fmt.Errorf("parse %s URL: %w", service, err)
	}
	if !parsedURL.IsAbs() || parsedURL.Host == "" {
		return nil, fmt.Errorf("%s URL must be absolute", service)
	}
	if parsedURL.Scheme != "http" && parsedURL.Scheme != "https" {
		return nil, fmt.Errorf("%s URL scheme must be http or https", service)
	}
	// Keep credentials solely in headers so transport diagnostics cannot expose
	// URL userinfo or query parameters.
	if parsedURL.User != nil || parsedURL.RawQuery != "" || parsedURL.Fragment != "" {
		return nil, fmt.Errorf("%s URL must not contain credentials, query, or fragment", service)
	}

	return &starr.Config{
		APIKey: apiKey,
		URL:    strings.TrimSuffix(baseURL, "/"),
		Client: limitResponses(httpClient),
	}, nil
}

func NormalizeRequestError(service, operation string, err error) error {
	if errors.Is(err, ErrResponseTooLarge) {
		return fmt.Errorf("%s: %w", operation, ErrResponseTooLarge)
	}
	var requestError *starr.ReqError
	if errors.As(err, &requestError) {
		// Starr retains response bodies in ReqError. Return only the status so an
		// upstream error page cannot leak credentials or unrelated server data.
		return fmt.Errorf(
			"%s: %w",
			operation,
			&HTTPError{Service: service, StatusCode: requestError.Code},
		)
	}
	return fmt.Errorf("%s: %w", operation, err)
}

func limitResponses(client *http.Client) *http.Client {
	limited := *client
	transport := limited.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	limited.Transport = &responseLimitTransport{
		next:  transport,
		limit: MaximumResponseBytes,
	}
	return &limited
}

type responseLimitTransport struct {
	next  http.RoundTripper
	limit int64
}

func (transport *responseLimitTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := transport.next.RoundTrip(request)
	if err != nil {
		return nil, err
	}
	if response.Body == nil {
		return response, nil
	}
	if response.ContentLength > transport.limit {
		_ = response.Body.Close()
		return nil, ErrResponseTooLarge
	}
	response.Body = &limitedReadCloser{
		body:      response.Body,
		remaining: transport.limit,
	}
	return response, nil
}

type limitedReadCloser struct {
	body      io.ReadCloser
	remaining int64
}

func (reader *limitedReadCloser) Read(buffer []byte) (int, error) {
	if reader.remaining > 0 {
		if int64(len(buffer)) > reader.remaining {
			buffer = buffer[:reader.remaining]
		}
		read, err := reader.body.Read(buffer)
		reader.remaining -= int64(read)
		return read, err
	}

	var extra [1]byte
	read, err := reader.body.Read(extra[:])
	if read > 0 {
		return 0, ErrResponseTooLarge
	}
	return 0, err
}

func (reader *limitedReadCloser) Close() error {
	return reader.body.Close()
}

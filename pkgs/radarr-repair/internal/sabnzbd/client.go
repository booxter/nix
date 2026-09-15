package sabnzbd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const maximumResponseBytes = 8 << 20

var errResponseTooLarge = errors.New("SABnzbd response is too large")

type HTTPError struct {
	StatusCode int
}

func (failure *HTTPError) Error() string {
	return fmt.Sprintf("SABnzbd returned HTTP status %d", failure.StatusCode)
}

type Client struct {
	endpoint       *url.URL
	apiKey         string
	httpClient     *http.Client
	requestTimeout time.Duration
}

// Tagged Go SABnzbd clients omit history fields needed to distinguish stable
// completed output. Keep this bounded read adapter local until one exposes the
// required data without discarding it.
func New(
	endpoint, apiKey string,
	requestTimeout time.Duration,
	httpClient *http.Client,
) (*Client, error) {
	if httpClient == nil {
		return nil, fmt.Errorf("SABnzbd HTTP client is required")
	}
	if requestTimeout <= 0 {
		return nil, fmt.Errorf("SABnzbd request timeout must be positive")
	}
	if apiKey == "" || strings.TrimSpace(apiKey) != apiKey || strings.ContainsRune(apiKey, '\x00') {
		return nil, fmt.Errorf("SABnzbd API key is invalid")
	}
	parsed, err := url.Parse(endpoint)
	if err != nil {
		return nil, fmt.Errorf("parse SABnzbd URL: %w", err)
	}
	if !parsed.IsAbs() || parsed.Host == "" {
		return nil, fmt.Errorf("SABnzbd URL must be absolute")
	}
	if parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, fmt.Errorf("SABnzbd URL must not contain credentials, query, or fragment")
	}
	if parsed.Scheme != "https" && (parsed.Scheme != "http" || !isLoopbackHost(parsed.Hostname())) {
		return nil, fmt.Errorf("SABnzbd URL must use HTTPS or loopback HTTP")
	}
	return &Client{
		endpoint: parsed, apiKey: apiKey, httpClient: httpClient, requestTimeout: requestTimeout,
	}, nil
}

func (client *Client) get(ctx context.Context, values url.Values, output any) error {
	requestURL := *client.endpoint
	query := requestURL.Query()
	for key, entries := range values {
		for _, value := range entries {
			query.Add(key, value)
		}
	}
	query.Set("apikey", client.apiKey)
	query.Set("output", "json")
	requestURL.RawQuery = query.Encode()

	requestContext, cancel := context.WithTimeout(ctx, client.requestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(requestContext, http.MethodGet, requestURL.String(), nil)
	if err != nil {
		return fmt.Errorf("create SABnzbd request")
	}
	request.Header.Set("Accept", "application/json")
	response, err := client.httpClient.Do(request)
	if err != nil {
		if contextError := requestContext.Err(); contextError != nil {
			return fmt.Errorf("send SABnzbd request: %w", contextError)
		}
		// The request URL contains the API key, so the transport error is not
		// safe to retain or return.
		return fmt.Errorf("send SABnzbd request failed")
	}
	body, err := readResponse(response)
	if err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	if err := decoder.Decode(output); err != nil {
		return fmt.Errorf("decode SABnzbd response: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("SABnzbd response contains more than one JSON value")
		}
		return fmt.Errorf("decode SABnzbd response: %w", err)
	}
	return nil
}

func readResponse(response *http.Response) ([]byte, error) {
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, &HTTPError{StatusCode: response.StatusCode}
	}
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return nil, fmt.Errorf("SABnzbd response content type is not application/json")
	}
	if response.ContentLength > maximumResponseBytes {
		return nil, errResponseTooLarge
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maximumResponseBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read SABnzbd response: %w", err)
	}
	if len(body) > maximumResponseBytes {
		return nil, errResponseTooLarge
	}
	return body, nil
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(strings.TrimSuffix(host, "."), "localhost") {
		return true
	}
	address := net.ParseIP(host)
	return address != nil && address.IsLoopback()
}

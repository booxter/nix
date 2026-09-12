package transmission

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"mime"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

const (
	maximumResponseBytes = 32 << 20
	sessionIDHeader      = "X-Transmission-Session-Id"
)

var errResponseTooLarge = errors.New("Transmission response is too large")

type HTTPError struct {
	StatusCode int
}

func (err *HTTPError) Error() string {
	return fmt.Sprintf("Transmission returned HTTP status %d", err.StatusCode)
}

type RPCError struct {
	Code int
}

func (err *RPCError) Error() string {
	return fmt.Sprintf("Transmission returned JSON-RPC error %d", err.Code)
}

type Client struct {
	endpoint       *url.URL
	httpClient     *http.Client
	requestTimeout time.Duration
	nextRequestID  atomic.Uint64
	sessionMutex   sync.RWMutex
	sessionID      string
}

var _ controller.TransmissionReader = (*Client)(nil)

func New(endpoint string, requestTimeout time.Duration, httpClient *http.Client) (*Client, error) {
	if httpClient == nil {
		return nil, fmt.Errorf("Transmission HTTP client is required")
	}
	if requestTimeout <= 0 {
		return nil, fmt.Errorf("Transmission request timeout must be positive")
	}
	parsed, err := url.Parse(endpoint)
	if err != nil {
		return nil, fmt.Errorf("parse Transmission URL: %w", err)
	}
	if !parsed.IsAbs() || parsed.Host == "" {
		return nil, fmt.Errorf("Transmission URL must be absolute")
	}
	if parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, fmt.Errorf("Transmission URL must not contain credentials, query, or fragment")
	}
	if parsed.Scheme != "https" && (parsed.Scheme != "http" || !isLoopbackHost(parsed.Hostname())) {
		return nil, fmt.Errorf("Transmission URL must use HTTPS or loopback HTTP")
	}

	return &Client{
		endpoint:       parsed,
		httpClient:     httpClient,
		requestTimeout: requestTimeout,
	}, nil
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(strings.TrimSuffix(host, "."), "localhost") {
		return true
	}
	address := net.ParseIP(host)
	return address != nil && address.IsLoopback()
}

type rpcRequest struct {
	JSONRPC string            `json:"jsonrpc"`
	ID      uint64            `json:"id"`
	Method  string            `json:"method"`
	Params  torrentGetRequest `json:"params"`
}

type torrentGetRequest struct {
	IDs    []string `json:"ids"`
	Fields []string `json:"fields"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      uint64          `json:"id"`
	Result  json.RawMessage `json:"result"`
	Error   *rpcError       `json:"error"`
}

type rpcError struct {
	Code int `json:"code"`
}

func (client *Client) rpc(ctx context.Context, method string, params torrentGetRequest) (json.RawMessage, error) {
	requestID := client.nextRequestID.Add(1)
	payload, err := json.Marshal(rpcRequest{
		JSONRPC: "2.0",
		ID:      requestID,
		Method:  method,
		Params:  params,
	})
	if err != nil {
		return nil, fmt.Errorf("encode Transmission request: %w", err)
	}

	requestContext, cancel := context.WithTimeout(ctx, client.requestTimeout)
	defer cancel()

	for attempt := 0; attempt < 2; attempt++ {
		response, err := client.do(requestContext, payload)
		if err != nil {
			return nil, err
		}
		if response.StatusCode == http.StatusConflict && attempt == 0 {
			sessionID := response.Header.Get(sessionIDHeader)
			_ = response.Body.Close()
			if sessionID == "" || strings.ContainsRune(sessionID, '\x00') {
				return nil, fmt.Errorf("Transmission session negotiation returned no valid session ID")
			}
			client.setSessionID(sessionID)
			continue
		}

		body, err := readResponse(response)
		if err != nil {
			return nil, err
		}
		var envelope rpcResponse
		if err := decodeOneJSON(body, &envelope); err != nil {
			return nil, fmt.Errorf("decode Transmission JSON-RPC response: %w", err)
		}
		if envelope.JSONRPC != "2.0" {
			return nil, fmt.Errorf("Transmission returned unsupported JSON-RPC version %q", envelope.JSONRPC)
		}
		if envelope.ID != requestID {
			return nil, fmt.Errorf("Transmission returned mismatched JSON-RPC request ID")
		}
		if envelope.Error != nil {
			return nil, &RPCError{Code: envelope.Error.Code}
		}
		if len(envelope.Result) == 0 || bytes.Equal(envelope.Result, []byte("null")) {
			return nil, fmt.Errorf("Transmission JSON-RPC response has no result")
		}
		return envelope.Result, nil
	}

	return nil, fmt.Errorf("Transmission session negotiation failed")
}

func (client *Client) do(ctx context.Context, payload []byte) (*http.Response, error) {
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		client.endpoint.String(),
		bytes.NewReader(payload),
	)
	if err != nil {
		return nil, fmt.Errorf("create Transmission request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	if sessionID := client.getSessionID(); sessionID != "" {
		request.Header.Set(sessionIDHeader, sessionID)
	}

	response, err := client.httpClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("send Transmission request: %w", err)
	}
	return response, nil
}

func (client *Client) getSessionID() string {
	client.sessionMutex.RLock()
	defer client.sessionMutex.RUnlock()
	return client.sessionID
}

func (client *Client) setSessionID(sessionID string) {
	client.sessionMutex.Lock()
	defer client.sessionMutex.Unlock()
	client.sessionID = sessionID
}

func readResponse(response *http.Response) ([]byte, error) {
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, &HTTPError{StatusCode: response.StatusCode}
	}
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return nil, fmt.Errorf("Transmission response content type is not application/json")
	}
	if response.ContentLength > maximumResponseBytes {
		return nil, errResponseTooLarge
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maximumResponseBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read Transmission response: %w", err)
	}
	if len(body) > maximumResponseBytes {
		return nil, errResponseTooLarge
	}
	return body, nil
}

func decodeOneJSON(data []byte, output any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	if err := decoder.Decode(output); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("response contains more than one JSON value")
		}
		return err
	}
	return nil
}

func finiteFraction(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0) && value >= 0 && value <= 1
}

func unixTime(value int64) (*time.Time, error) {
	if value < 0 {
		return nil, fmt.Errorf("timestamp must not be negative")
	}
	if value == 0 {
		return nil, nil
	}
	timestamp := time.Unix(value, 0).UTC()
	return &timestamp, nil
}

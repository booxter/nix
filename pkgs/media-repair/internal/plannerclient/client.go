package plannerclient

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
)

const (
	radarrPlanningURL       = "http://planner/v3/repair-plans"
	lidarrPlanningURL       = "http://planner/lidarr/v3/repair-plans"
	maxDecisionResponseSize = 64 << 10
)

type FailureKind uint8

const (
	FailureUnavailable FailureKind = iota + 1
	FailureTimeout
	FailureHTTP
	FailureInvalidResponse
)

type Failure struct {
	Kind       FailureKind
	StatusCode int
	cause      error
}

func (failure *Failure) Error() string {
	switch failure.Kind {
	case FailureUnavailable:
		return "repair planner is unavailable"
	case FailureTimeout:
		return "repair planner timed out"
	case FailureHTTP:
		return fmt.Sprintf("repair planner returned HTTP status %d", failure.StatusCode)
	case FailureInvalidResponse:
		return "repair planner returned an invalid response"
	default:
		return "repair planner failed"
	}
}

func (failure *Failure) Unwrap() error {
	return failure.cause
}

func (failure *Failure) PlanningFailure() planningrunner.Failure {
	if failure == nil {
		return planningrunner.Failure{Kind: planningrunner.FailureUnexpected}
	}
	switch failure.Kind {
	case FailureUnavailable:
		return planningrunner.Failure{Kind: planningrunner.FailureUnavailable}
	case FailureTimeout:
		return planningrunner.Failure{Kind: planningrunner.FailureTimeout}
	case FailureHTTP:
		return planningrunner.Failure{
			Kind: planningrunner.FailureHTTP, StatusCode: failure.StatusCode,
		}
	case FailureInvalidResponse:
		return planningrunner.Failure{Kind: planningrunner.FailureInvalidResult}
	default:
		return planningrunner.Failure{Kind: planningrunner.FailureUnexpected}
	}
}

type Client struct {
	httpClient     *http.Client
	transport      *http.Transport
	requestTimeout time.Duration
}

var _ controller.Planner = (*Client)(nil)

func New(socketPath string, requestTimeout time.Duration) (*Client, error) {
	if socketPath == "" || strings.ContainsRune(socketPath, '\x00') ||
		!filepath.IsAbs(socketPath) || filepath.Clean(socketPath) != socketPath {
		return nil, fmt.Errorf("planner socket must be an absolute clean path")
	}
	if requestTimeout <= 0 {
		return nil, fmt.Errorf("planner request timeout must be positive")
	}

	dialer := &net.Dialer{}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, "unix", socketPath)
		},
		DisableCompression:  true,
		MaxIdleConns:        2,
		MaxIdleConnsPerHost: 2,
		IdleConnTimeout:     30 * time.Second,
	}
	return &Client{
		httpClient: &http.Client{
			Transport: transport,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		transport:      transport,
		requestTimeout: requestTimeout,
	}, nil
}

func (client *Client) Close() {
	if client != nil && client.transport != nil {
		client.transport.CloseIdleConnections()
	}
}

func (client *Client) Plan(
	ctx context.Context,
	repairCase contracts.RepairCaseV3,
) (contracts.RepairDecisionV3, error) {
	if client == nil || client.httpClient == nil || client.requestTimeout <= 0 {
		return contracts.RepairDecisionV3{}, fmt.Errorf("planner client is not configured")
	}
	payload, err := contracts.EncodeCase(repairCase)
	if err != nil {
		return contracts.RepairDecisionV3{}, fmt.Errorf("construct planner request: %w", err)
	}

	data, err := client.postPlan(ctx, radarrPlanningURL, payload)
	if err != nil {
		return contracts.RepairDecisionV3{}, err
	}
	decision, err := contracts.DecodeDecision(data)
	if err != nil {
		return contracts.RepairDecisionV3{}, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	if decision.CaseID() != repairCase.CaseID {
		return contracts.RepairDecisionV3{}, &Failure{Kind: FailureInvalidResponse}
	}
	return decision, nil
}

func (client *Client) postPlan(ctx context.Context, endpoint string, payload []byte) ([]byte, error) {
	if client == nil || client.httpClient == nil || client.requestTimeout <= 0 {
		return nil, fmt.Errorf("planner client is not configured")
	}
	requestContext, cancel := context.WithTimeout(ctx, client.requestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(
		requestContext, http.MethodPost, endpoint, bytes.NewReader(payload),
	)
	if err != nil {
		return nil, fmt.Errorf("construct planner HTTP request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.httpClient.Do(request)
	if err != nil {
		return nil, client.requestFailure(ctx, requestContext, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, &Failure{Kind: FailureHTTP, StatusCode: response.StatusCode}
	}
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return nil, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, maxDecisionResponseSize+1))
	if err != nil {
		return nil, client.requestFailure(ctx, requestContext, err)
	}
	if len(data) > maxDecisionResponseSize {
		return nil, &Failure{Kind: FailureInvalidResponse}
	}
	return data, nil
}

func (client *Client) requestFailure(
	callerContext context.Context,
	requestContext context.Context,
	cause error,
) error {
	if err := callerContext.Err(); err != nil {
		return err
	}
	if errors.Is(requestContext.Err(), context.DeadlineExceeded) {
		return &Failure{Kind: FailureTimeout, cause: cause}
	}
	return &Failure{Kind: FailureUnavailable, cause: cause}
}

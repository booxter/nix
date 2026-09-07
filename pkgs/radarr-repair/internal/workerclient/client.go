package workerclient

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
	"sort"
	"strings"
	"sync/atomic"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const probeURL = "http://worker/v1/probe"

type FailureKind uint8

const (
	FailureUnavailable FailureKind = iota + 1
	FailureTimeout
	FailureHTTP
	FailureInvalidResponse
	FailureRejected
)

type Failure struct {
	Kind       FailureKind
	Reason     workercontracts.Reason
	StatusCode int
	cause      error
}

func (failure *Failure) Error() string {
	switch failure.Kind {
	case FailureUnavailable:
		return "media probe worker is unavailable"
	case FailureTimeout:
		return "media probe worker timed out"
	case FailureHTTP:
		return fmt.Sprintf("media probe worker returned HTTP status %d", failure.StatusCode)
	case FailureInvalidResponse:
		return "media probe worker returned an invalid response"
	case FailureRejected:
		return fmt.Sprintf("media probe worker rejected the request: %s", failure.Reason)
	default:
		return "media probe worker failed"
	}
}

func (failure *Failure) Unwrap() error {
	return failure.cause
}

type mediaRoot struct {
	id   string
	path string
}

type Client struct {
	httpClient     *http.Client
	transport      *http.Transport
	roots          []mediaRoot
	requestTimeout time.Duration
	nextRequestID  atomic.Uint64
}

var _ controller.MediaProbeReader = (*Client)(nil)

func New(
	socketPath string,
	rootPaths map[string]string,
	requestTimeout time.Duration,
) (*Client, error) {
	if socketPath == "" || strings.ContainsRune(socketPath, '\x00') ||
		!filepath.IsAbs(socketPath) || filepath.Clean(socketPath) != socketPath {
		return nil, fmt.Errorf("worker socket must be an absolute clean path")
	}
	if requestTimeout <= 0 {
		return nil, fmt.Errorf("worker request timeout must be positive")
	}
	if len(rootPaths) == 0 {
		return nil, fmt.Errorf("at least one media root is required")
	}

	rootIDs := make([]string, 0, len(rootPaths))
	for rootID := range rootPaths {
		rootIDs = append(rootIDs, rootID)
	}
	sort.Strings(rootIDs)
	roots := make([]mediaRoot, 0, len(rootIDs))
	seenPaths := make(map[string]string, len(rootIDs))
	for _, rootID := range rootIDs {
		rootPath := rootPaths[rootID]
		if rootPath == "" || strings.ContainsRune(rootPath, '\x00') ||
			!filepath.IsAbs(rootPath) || filepath.Clean(rootPath) != rootPath {
			return nil, fmt.Errorf("media root %q must have an absolute clean path", rootID)
		}
		if previousID, exists := seenPaths[rootPath]; exists {
			return nil, fmt.Errorf(
				"media roots %q and %q have the same path",
				previousID,
				rootID,
			)
		}
		if err := validateRootID(rootID); err != nil {
			return nil, fmt.Errorf("media root %q has an invalid ID: %w", rootID, err)
		}
		seenPaths[rootPath] = rootID
		roots = append(roots, mediaRoot{id: rootID, path: rootPath})
	}
	sort.Slice(roots, func(left, right int) bool {
		if len(roots[left].path) == len(roots[right].path) {
			return roots[left].id < roots[right].id
		}
		return len(roots[left].path) > len(roots[right].path)
	})

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
		roots:          roots,
		requestTimeout: requestTimeout,
	}, nil
}

func (client *Client) Close() {
	if client != nil && client.transport != nil {
		client.transport.CloseIdleConnections()
	}
}

func (client *Client) Probe(
	ctx context.Context,
	target controller.MediaProbeTarget,
) (controller.ProbeEvidence, error) {
	if client == nil || client.httpClient == nil || client.requestTimeout <= 0 {
		return controller.ProbeEvidence{}, fmt.Errorf("worker client is not configured")
	}
	rootID, components, err := client.resolve(target.AbsolutePath)
	if err != nil {
		return controller.ProbeEvidence{}, err
	}
	requestID := fmt.Sprintf("request:%d", client.nextRequestID.Add(1))
	payload, err := workercontracts.EncodeProbeRequest(workercontracts.ProbeRequestV1{
		ExpectedFingerprint: target.Fingerprint.Fingerprint(),
		Operation:           workercontracts.ProbeV1,
		PathComponents:      components,
		RequestID:           requestID,
		RootID:              rootID,
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	})
	if err != nil {
		return controller.ProbeEvidence{}, fmt.Errorf("construct worker probe request: %w", err)
	}

	requestContext, cancel := context.WithTimeout(ctx, client.requestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(
		requestContext,
		http.MethodPost,
		probeURL,
		bytes.NewReader(payload),
	)
	if err != nil {
		return controller.ProbeEvidence{}, fmt.Errorf("construct worker HTTP request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.httpClient.Do(request)
	if err != nil {
		return controller.ProbeEvidence{}, client.requestFailure(ctx, requestContext, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return controller.ProbeEvidence{}, &Failure{
			Kind: FailureHTTP, StatusCode: response.StatusCode,
		}
	}
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, workercontracts.MaxProbeResponseBytes+1))
	if err != nil {
		return controller.ProbeEvidence{}, client.requestFailure(ctx, requestContext, err)
	}
	if len(data) > workercontracts.MaxProbeResponseBytes {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureInvalidResponse}
	}
	probeResponse, err := workercontracts.DecodeProbeResponse(data)
	if err != nil {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	if probeResponse.RequestID() != requestID {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureInvalidResponse}
	}
	if probeResponse.Failure != nil {
		return controller.ProbeEvidence{}, &Failure{
			Kind: FailureRejected, Reason: probeResponse.Failure.Reason,
		}
	}
	if probeResponse.Success == nil {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureInvalidResponse}
	}
	return convertEvidence(probeResponse.Success.Evidence), nil
}

func (client *Client) resolve(absolutePath string) (string, []string, error) {
	if absolutePath == "" || strings.ContainsRune(absolutePath, '\x00') ||
		!filepath.IsAbs(absolutePath) || filepath.Clean(absolutePath) != absolutePath {
		return "", nil, fmt.Errorf("media path must be an absolute clean path")
	}
	for _, root := range client.roots {
		relative, err := filepath.Rel(root.path, absolutePath)
		if err != nil || relative == "." || relative == ".." ||
			strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			continue
		}
		return root.id, strings.Split(filepath.ToSlash(relative), "/"), nil
	}
	return "", nil, fmt.Errorf("media path is outside configured roots")
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

func validateRootID(rootID string) error {
	_, err := workercontracts.EncodeProbeRequest(workercontracts.ProbeRequestV1{
		ExpectedFingerprint: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
		Operation:           workercontracts.ProbeV1,
		PathComponents:      []string{"file"},
		RequestID:           "request:configuration",
		RootID:              rootID,
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	})
	return err
}

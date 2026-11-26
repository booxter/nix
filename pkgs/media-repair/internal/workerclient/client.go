package workerclient

import (
	"context"
	"fmt"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

type FailureKind uint8

const (
	FailureInvalidResponse FailureKind = iota + 1
	FailureRejected
)

type Failure struct {
	Kind   FailureKind
	Reason workercontracts.Reason
	cause  error
}

func (failure *Failure) Error() string {
	switch failure.Kind {
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
	runner         RequestRunner
	roots          []mediaRoot
	requestTimeout time.Duration
	stageTimeout   time.Duration
	nextRequestID  atomic.Uint64
}

var _ controller.MediaProbeReader = (*Client)(nil)

func newClient(rootPaths map[string]string, requestTimeout, stageTimeout time.Duration) (*Client, error) {
	if requestTimeout <= 0 {
		return nil, fmt.Errorf("worker request timeout must be positive")
	}
	if stageTimeout <= 0 {
		return nil, fmt.Errorf("worker stage timeout must be positive")
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

	return &Client{
		roots:          roots,
		requestTimeout: requestTimeout,
		stageTimeout:   max(requestTimeout, stageTimeout),
	}, nil
}

func (client *Client) Probe(
	ctx context.Context,
	target controller.MediaProbeTarget,
) (controller.MediaProbeOutcome, error) {
	if !client.configured() {
		return controller.MediaProbeOutcome{}, fmt.Errorf("worker client is not configured")
	}
	rootID, components, err := client.resolve(target.AbsolutePath)
	if err != nil {
		return controller.MediaProbeOutcome{}, err
	}
	requestID := client.nextID()
	payload, err := workercontracts.EncodeProbeRequest(workercontracts.ProbeRequestV1{
		ExpectedFingerprint: target.Fingerprint.StrictFingerprint(),
		Operation:           workercontracts.ProbeV1,
		PathComponents:      components,
		RequestID:           requestID,
		RootID:              rootID,
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	})
	if err != nil {
		return controller.MediaProbeOutcome{}, fmt.Errorf("construct worker probe request: %w", err)
	}

	data, err := client.post(ctx, "/v1/probe", payload, workercontracts.MaxProbeResponseBytes)
	if err != nil {
		return controller.MediaProbeOutcome{}, err
	}
	probeResponse, err := workercontracts.DecodeProbeResponse(data)
	if err != nil {
		return controller.MediaProbeOutcome{}, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	if probeResponse.RequestID() != requestID {
		return controller.MediaProbeOutcome{}, &Failure{Kind: FailureInvalidResponse}
	}
	if probeResponse.Failure != nil {
		if reason, retained := retainedProbeFailure(probeResponse.Failure.Reason); retained {
			return controller.FailedMediaProbe(reason), nil
		}
		return controller.MediaProbeOutcome{}, &Failure{
			Kind: FailureRejected, Reason: probeResponse.Failure.Reason,
		}
	}
	if probeResponse.Success == nil {
		return controller.MediaProbeOutcome{}, &Failure{Kind: FailureInvalidResponse}
	}
	return controller.SuccessfulMediaProbe(EvidenceFromWorker(probeResponse.Success.Evidence)), nil
}

// ResolvePublishedPath translates the worker's root-relative publication
// result back to the path visible to Radarr through the same configured roots.
func (client *Client) ResolvePublishedPath(
	rootID string,
	pathComponents []string,
) (string, error) {
	if !client.configured() {
		return "", fmt.Errorf("worker client is not configured")
	}
	if len(pathComponents) == 0 || len(pathComponents) > 32 {
		return "", fmt.Errorf("published media path is invalid")
	}
	for _, component := range pathComponents {
		if !validPublishedPathComponent(component) {
			return "", fmt.Errorf("published media path is invalid")
		}
	}

	for _, root := range client.roots {
		if root.id != rootID {
			continue
		}
		absolutePath := filepath.Join(
			root.path,
			filepath.FromSlash(strings.Join(pathComponents, "/")),
		)
		resolvedRoot, resolvedComponents, err := client.resolve(absolutePath)
		if err != nil || resolvedRoot != rootID || !slices.Equal(resolvedComponents, pathComponents) {
			return "", fmt.Errorf("published media path does not match its worker root")
		}
		return absolutePath, nil
	}
	return "", fmt.Errorf("published media path has an unknown worker root")
}

func (client *Client) configured() bool {
	return client != nil && client.runner != nil && client.requestTimeout > 0
}

func (client *Client) nextID() string {
	return fmt.Sprintf("request:%d", client.nextRequestID.Add(1))
}

func (client *Client) post(
	ctx context.Context,
	path string,
	payload []byte,
	responseLimit int,
) ([]byte, error) {
	return client.postWithTimeout(ctx, path, payload, responseLimit, client.requestTimeout)
}

func (client *Client) postWithTimeout(
	ctx context.Context,
	path string,
	payload []byte,
	responseLimit int,
	timeout time.Duration,
) ([]byte, error) {
	requestContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return client.runner.Run(requestContext, path, payload, responseLimit)
}

func retainedProbeFailure(reason workercontracts.Reason) (controller.MediaProbeReason, bool) {
	// Media-specific probe failures are useful negative evidence. Root, path,
	// fingerprint, protocol, and internal failures instead mean collection could
	// not be trusted and remain errors.
	switch reason {
	case workercontracts.NotRegularFile:
		return controller.MediaProbeNotRegularFile, true
	case workercontracts.UnsupportedFormat:
		return controller.MediaProbeUnsupportedFormat, true
	case workercontracts.Timeout:
		return controller.MediaProbeTimeout, true
	case workercontracts.ProbeError:
		return controller.MediaProbeError, true
	case workercontracts.InvalidOutput:
		return controller.MediaProbeInvalidOutput, true
	default:
		return "", false
	}
}

func (client *Client) resolve(absolutePath string) (string, []string, error) {
	if absolutePath == "" || strings.ContainsRune(absolutePath, '\x00') ||
		!filepath.IsAbs(absolutePath) || filepath.Clean(absolutePath) != absolutePath {
		return "", nil, fmt.Errorf("media path must be an absolute clean path")
	}
	for _, root := range client.roots {
		relative, contained := relativeToRoot(root.path, absolutePath)
		if !contained {
			continue
		}
		return root.id, strings.Split(filepath.ToSlash(relative), "/"), nil
	}
	return "", nil, fmt.Errorf("media path is outside configured roots")
}

func relativeToRoot(root, absolutePath string) (string, bool) {
	if absolutePath == "" || strings.ContainsRune(absolutePath, '\x00') ||
		!filepath.IsAbs(absolutePath) || filepath.Clean(absolutePath) != absolutePath {
		return "", false
	}
	relative, err := filepath.Rel(root, absolutePath)
	if err != nil || relative == "." || relative == ".." ||
		strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", false
	}
	return relative, true
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

func validPublishedPathComponent(component string) bool {
	if component == "" || component == "." || component == ".." ||
		utf8.RuneCountInString(component) > 255 {
		return false
	}
	for _, character := range component {
		if character == '/' || character == '\\' || character <= 0x1f || character == 0x7f {
			return false
		}
	}
	return true
}

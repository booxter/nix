package workerclient

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

const (
	stageJoinPath = "/v1/join/stage"
	publishPath   = "/v1/join/publish"
	discardPath   = "/v1/join/discard"
	inspectPath   = "/v1/join/inspect"
)

type StageJoinExchange struct {
	Request  workercontracts.StageJoinRequestV1
	Response workercontracts.StageJoinResponseV1
}

type Artifact struct {
	ID          string
	Fingerprint string
}

func (client *Client) StageJoin(
	ctx context.Context,
	executionID string,
	authorized decisionpolicy.AuthorizedJoin,
	absolutePaths map[controller.FileID]string,
) (StageJoinExchange, error) {
	if !client.configured() {
		return StageJoinExchange{}, fmt.Errorf("worker client is not configured")
	}
	paths := make([]string, len(authorized.OrderedParts))
	for position, part := range authorized.OrderedParts {
		path, found := absolutePaths[part.FileID]
		if !found {
			return StageJoinExchange{}, fmt.Errorf("authorized join part %q has no local path", part.FileID)
		}
		paths[position] = path
	}
	rootID, components, err := client.resolveTogether(paths)
	if err != nil {
		return StageJoinExchange{}, err
	}
	parts := make([]workercontracts.StageJoinPartV1, len(authorized.OrderedParts))
	for position, part := range authorized.OrderedParts {
		parts[position] = workercontracts.StageJoinPartV1{
			ExpectedFingerprint: part.Fingerprint.StrictFingerprint(),
			FileID:              string(part.FileID),
			PathComponents:      components[position],
		}
	}
	request := workercontracts.StageJoinRequestV1{
		CapabilityID:        authorized.CapabilityID,
		CaseID:              authorized.CaseID,
		DurationToleranceMS: authorized.DurationToleranceMS,
		ExecutionID:         executionID,
		ExpectedDurationMS:  authorized.ExpectedDurationMS,
		ExpectedSourceBytes: authorized.SourceBytes,
		ExpectedStreamCount: int64(len(authorized.ExpectedStreamLayout.Streams)),
		Operation:           workercontracts.StageJoinV1,
		OutputContainer:     workercontracts.OutputContainer(authorized.OutputContainer),
		Parts:               parts,
		RequestID:           client.nextID(),
		RootID:              rootID,
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	}
	payload, err := workercontracts.EncodeStageJoinRequest(request)
	if err != nil {
		return StageJoinExchange{}, fmt.Errorf("construct worker stage-join request: %w", err)
	}
	response, err := callJoin(
		client,
		ctx,
		stageJoinPath,
		client.stageTimeout,
		payload,
		request.RequestID,
		workercontracts.DecodeStageJoinResponse,
		func(response workercontracts.StageJoinResponseV1) string { return response.RequestID() },
	)
	if err != nil {
		return StageJoinExchange{}, err
	}
	return StageJoinExchange{Request: request, Response: response}, nil
}

func (client *Client) PublishJoin(
	ctx context.Context,
	artifact Artifact,
) (workercontracts.PublishResponseV1, error) {
	if !client.configured() {
		return workercontracts.PublishResponseV1{}, fmt.Errorf("worker client is not configured")
	}
	request := workercontracts.PublishRequestV1{
		ArtifactFingerprint: artifact.Fingerprint,
		ArtifactID:          artifact.ID,
		Operation:           workercontracts.PublishV1,
		RequestID:           client.nextID(),
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	}
	payload, err := workercontracts.EncodePublishRequest(request)
	if err != nil {
		return workercontracts.PublishResponseV1{}, fmt.Errorf(
			"construct worker publish request: %w",
			err,
		)
	}
	return callJoin(
		client,
		ctx,
		publishPath,
		client.requestTimeout,
		payload,
		request.RequestID,
		workercontracts.DecodePublishResponse,
		func(response workercontracts.PublishResponseV1) string { return response.RequestID() },
	)
}

func (client *Client) DiscardJoin(
	ctx context.Context,
	artifact Artifact,
) (workercontracts.DiscardResponseV1, error) {
	if !client.configured() {
		return workercontracts.DiscardResponseV1{}, fmt.Errorf("worker client is not configured")
	}
	request := workercontracts.DiscardRequestV1{
		ArtifactFingerprint: artifact.Fingerprint,
		ArtifactID:          artifact.ID,
		Operation:           workercontracts.DiscardV1,
		RequestID:           client.nextID(),
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	}
	payload, err := workercontracts.EncodeDiscardRequest(request)
	if err != nil {
		return workercontracts.DiscardResponseV1{}, fmt.Errorf(
			"construct worker discard request: %w",
			err,
		)
	}
	return callJoin(
		client,
		ctx,
		discardPath,
		client.requestTimeout,
		payload,
		request.RequestID,
		workercontracts.DecodeDiscardResponse,
		func(response workercontracts.DiscardResponseV1) string { return response.RequestID() },
	)
}

func (client *Client) InspectJoin(
	ctx context.Context,
	executionID string,
) (workercontracts.InspectJoinResponseV1, error) {
	if !client.configured() {
		return workercontracts.InspectJoinResponseV1{}, fmt.Errorf(
			"worker client is not configured",
		)
	}
	request := workercontracts.InspectJoinRequestV1{
		ExecutionID:   executionID,
		Operation:     workercontracts.InspectJoinV1,
		RequestID:     client.nextID(),
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
	}
	payload, err := workercontracts.EncodeInspectJoinRequest(request)
	if err != nil {
		return workercontracts.InspectJoinResponseV1{}, fmt.Errorf(
			"construct worker join-inspection request: %w",
			err,
		)
	}
	return callJoin(
		client,
		ctx,
		inspectPath,
		client.requestTimeout,
		payload,
		request.RequestID,
		workercontracts.DecodeInspectJoinResponse,
		func(response workercontracts.InspectJoinResponseV1) string {
			return response.RequestID()
		},
	)
}

func callJoin[T any](
	client *Client,
	ctx context.Context,
	path string,
	timeout time.Duration,
	payload []byte,
	requestID string,
	decode func([]byte) (T, error),
	responseRequestID func(T) string,
) (T, error) {
	var zero T
	data, err := client.postWithTimeout(
		ctx, path, payload, workercontracts.MaxJoinResponseBytes, timeout,
	)
	if err != nil {
		return zero, err
	}
	response, err := decode(data)
	if err != nil {
		return zero, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	if responseRequestID(response) != requestID {
		return zero, &Failure{Kind: FailureInvalidResponse}
	}
	return response, nil
}

func (client *Client) resolveTogether(paths []string) (string, [][]string, error) {
	for _, root := range client.roots {
		components := make([][]string, len(paths))
		contained := true
		for position, path := range paths {
			relative, ok := relativeToRoot(root.path, path)
			if !ok {
				contained = false
				break
			}
			components[position] = strings.Split(filepath.ToSlash(relative), "/")
		}
		if contained {
			return root.id, components, nil
		}
	}
	return "", nil, fmt.Errorf("media files do not share a configured root")
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

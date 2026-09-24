package workerclient

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

func (client *Client) MaterializeTarAudio(
	ctx context.Context,
	archivePath string,
	fingerprint fileidentity.Snapshot,
	workspaceID string,
) (materialize.Success, error) {
	if !client.configured() {
		return materialize.Success{}, fmt.Errorf("worker client is not configured")
	}
	rootID, components, err := client.resolve(archivePath)
	if err != nil {
		return materialize.Success{}, err
	}
	requestID := client.nextID()
	payload, err := materialize.EncodeRequest(materialize.Request{
		SchemaVersion: materialize.SchemaVersion, RequestID: requestID,
		Operation: materialize.OperationMaterializeTar, RootID: rootID,
		SourceComponents: components, ExpectedFingerprint: fingerprint.Fingerprint(),
		WorkspaceID: workspaceID,
	})
	if err != nil {
		return materialize.Success{}, fmt.Errorf("construct worker materialization request: %w", err)
	}
	data, err := client.postWithTimeout(
		ctx, "/v1/materialize/tar-audio", payload,
		materialize.MaxResponseBytes, client.stageTimeout,
	)
	if err != nil {
		return materialize.Success{}, err
	}
	response, err := materialize.DecodeResponse(data)
	if err != nil {
		return materialize.Success{}, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	if response.Success != nil && response.Success.RequestID == requestID {
		return *response.Success, nil
	}
	if response.Failure != nil && response.Failure.RequestID == requestID {
		return materialize.Success{}, &materialize.Rejection{Reason: response.Failure.Reason}
	}
	return materialize.Success{}, &Failure{Kind: FailureInvalidResponse}
}

func (client *Client) MaterializeDirectoryAudio(
	ctx context.Context,
	directoryPath string,
	workspaceID string,
) (materialize.Success, error) {
	if !client.configured() {
		return materialize.Success{}, fmt.Errorf("worker client is not configured")
	}
	rootID, components, err := client.resolve(directoryPath)
	if err != nil {
		return materialize.Success{}, err
	}
	requestID := client.nextID()
	payload, err := materialize.EncodeRequest(materialize.Request{
		SchemaVersion: materialize.SchemaVersion, RequestID: requestID,
		Operation: materialize.OperationMaterializeDirectory, RootID: rootID,
		SourceComponents: components, WorkspaceID: workspaceID,
	})
	if err != nil {
		return materialize.Success{}, fmt.Errorf("construct worker materialization request: %w", err)
	}
	data, err := client.postWithTimeout(
		ctx, "/v1/materialize/directory-audio", payload,
		materialize.MaxResponseBytes, client.stageTimeout,
	)
	if err != nil {
		return materialize.Success{}, err
	}
	response, err := materialize.DecodeResponse(data)
	if err != nil {
		return materialize.Success{}, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	if response.Success != nil && response.Success.RequestID == requestID {
		return *response.Success, nil
	}
	if response.Failure != nil && response.Failure.RequestID == requestID {
		return materialize.Success{}, &materialize.Rejection{Reason: response.Failure.Reason}
	}
	return materialize.Success{}, &Failure{Kind: FailureInvalidResponse}
}

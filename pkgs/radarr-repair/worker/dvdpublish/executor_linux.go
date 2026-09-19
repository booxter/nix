package dvdpublish

import (
	"context"
	"errors"
	"fmt"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/dvdrequest"
	"github.com/booxter/nix-config/radarr-repair/worker/dvdstage"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
)

type Artifacts interface {
	PublishCompletedAt(string, string, workercontracts.OutputContainer,
		string, []string) ([]string, error)
}

type Executor struct{ artifacts Artifacts }

var _ Artifacts = (*mediafile.RootSet)(nil)

func NewExecutor(artifacts Artifacts) (*Executor, error) {
	if artifacts == nil {
		return nil, fmt.Errorf("DVD artifact storage is required")
	}
	return &Executor{artifacts: artifacts}, nil
}

func (executor *Executor) Execute(
	ctx context.Context, request workercontracts.DVDPublishRequestV1,
) workercontracts.DVDPublishResponseV1 {
	if executor == nil || ctx == nil {
		return failure(request.RequestID, "internal_error")
	}
	if ctx.Err() != nil {
		return failure(request.RequestID, "timeout")
	}
	spec := dvdrequest.Specification(request.StageRequest)
	artifactID, err := dvdstage.ArtifactID(spec)
	if err != nil || artifactID != request.ArtifactID {
		return failure(request.RequestID, "invalid_request")
	}
	navigation := spec.Navigation.PathComponents
	directory := navigation[:len(navigation)-2]
	location, err := executor.artifacts.PublishCompletedAt(spec.RootID, artifactID,
		workercontracts.OutputContainerMKV, request.ArtifactFingerprint, directory)
	if err != nil {
		return failure(request.RequestID, reasonFor(err))
	}
	return workercontracts.DVDPublishResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.DVDPublishSuccessV1{
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Operation:     workercontracts.PublishDVDRemuxV1,
			RequestID:     request.RequestID, Status: workercontracts.Ok,
			ArtifactID: artifactID, ArtifactFingerprint: request.ArtifactFingerprint,
			RootID: spec.RootID, PathComponents: location,
		},
	}
}

func failure(requestID string, reason workercontracts.BlurayPublishFailureResponseV1Reason) workercontracts.DVDPublishResponseV1 {
	return workercontracts.DVDPublishResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.DVDPublishFailureV1{
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Operation:     workercontracts.PublishDVDRemuxV1,
			RequestID:     requestID, Status: workercontracts.Failed, Reason: reason,
		},
	}
}

func reasonFor(err error) workercontracts.BlurayPublishFailureResponseV1Reason {
	var file *mediafile.Failure
	if errors.As(err, &file) {
		switch file.Kind {
		case mediafile.FailureFileUnavailable:
			return "artifact_not_found"
		case mediafile.FailureFingerprintMismatch:
			return "fingerprint_mismatch"
		case mediafile.FailureDestinationExists:
			return "destination_exists"
		case mediafile.FailureInvalidPath, mediafile.FailureUnknownRoot:
			return "invalid_request"
		}
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	return "internal_error"
}

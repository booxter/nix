package joinrequest

import (
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/joinstate"
)

func SuccessResponse(
	requestID string,
	artifactID string,
	staged joinstate.StagedArtifact,
) workercontracts.StageJoinResponseV1 {
	return workercontracts.StageJoinResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.StageJoinSuccessResponseV1{
			ArtifactFingerprint: staged.Fingerprint,
			ArtifactID:          artifactID,
			Evidence:            staged.Evidence,
			Operation:           workercontracts.StageJoinV1,
			RequestID:           requestID,
			SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
			SizeBytes:           staged.SizeBytes,
			Status:              workercontracts.Ok,
		},
	}
}

func FailureResponse(
	requestID string,
	reason workercontracts.StageJoinFailureReason,
) workercontracts.StageJoinResponseV1 {
	return workercontracts.StageJoinResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.StageJoinFailureResponseV1{
			Operation:     workercontracts.StageJoinV1,
			Reason:        reason,
			RequestID:     requestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status:        workercontracts.Failed,
		},
	}
}

func storedSuccess(
	requestID string,
	execution joinstate.Execution,
) workercontracts.StageJoinResponseV1 {
	if execution.Staged == nil {
		return FailureResponse(requestID, workercontracts.StageJoinInternalError)
	}
	return SuccessResponse(requestID, execution.ArtifactID, *execution.Staged)
}

func storedFailure(
	requestID string,
	execution joinstate.Execution,
) workercontracts.StageJoinResponseV1 {
	if execution.Failure == nil {
		return FailureResponse(requestID, workercontracts.StageJoinInternalError)
	}
	return FailureResponse(requestID, execution.Failure.Reason)
}

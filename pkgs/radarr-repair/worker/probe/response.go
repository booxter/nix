package workerprobe

import (
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/mediaevidence"
)

func SuccessResponse(
	requestID string,
	evidence controller.ProbeEvidence,
) workercontracts.ProbeResponseV1 {
	return workercontracts.ProbeResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.ProbeSuccessResponseV1{
			Evidence:      mediaevidence.FromProbe(evidence),
			Operation:     workercontracts.ProbeV1,
			RequestID:     requestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status:        workercontracts.Ok,
		},
	}
}

func FailureResponse(
	requestID string,
	reason workercontracts.Reason,
) workercontracts.ProbeResponseV1 {
	return workercontracts.ProbeResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.ProbeFailureResponseV1{
			Operation:     workercontracts.ProbeV1,
			Reason:        reason,
			RequestID:     requestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status:        workercontracts.Failed,
		},
	}
}

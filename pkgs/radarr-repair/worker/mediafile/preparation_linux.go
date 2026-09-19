package mediafile

import (
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

// PrepareStage recovers a completed artifact or clears an interrupted partial
// artifact before the caller starts a fresh media operation.
func PrepareStage(
	artifacts RecoverableStagedArtifacts,
	rootID, artifactID string,
	container workercontracts.OutputContainer,
) (CompletedArtifact, error) {
	status, completed, err := artifacts.InspectStaged(rootID, artifactID, container)
	if err != nil {
		if completed != nil {
			_ = completed.Close()
		}
		return nil, err
	}
	switch status {
	case StagedComplete:
		if completed == nil {
			return nil, &Failure{Kind: FailureInternal}
		}
		return completed, nil
	case StagedPartial:
		if completed != nil {
			_ = completed.Close()
			return nil, &Failure{Kind: FailureInternal}
		}
		removed, err := artifacts.RemovePartial(rootID, artifactID, container)
		if err != nil {
			return nil, err
		}
		if !removed {
			return nil, &Failure{Kind: FailureArtifactExists}
		}
		return nil, nil
	case StagedMissing:
		if completed == nil {
			return nil, nil
		}
		_ = completed.Close()
		return nil, &Failure{Kind: FailureInternal}
	default:
		if completed != nil {
			_ = completed.Close()
		}
		return nil, &Failure{Kind: FailureInternal}
	}
}

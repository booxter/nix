package mediafile

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

type RemuxResult struct {
	Fingerprint string
	SizeBytes   int64
	Evidence    controller.ProbeEvidence
}

// StageRemux retains output only after both the inputs and output are verified.
func StageRemux(
	ctx context.Context, artifacts StagedArtifacts, root, id string, sourceBytes int64,
	remux func(*os.File) (int64, error), verifyInputs func() error,
	probe func(context.Context, *os.File) (controller.ProbeEvidence, error),
	validate func(controller.ProbeEvidence) error,
) (result RemuxResult, returnedErr error) {
	artifact, err := artifacts.CreateStaged(root, id, workercontracts.OutputContainerMKV, sourceBytes)
	if err != nil {
		return result, err
	}
	retained := false
	defer func() {
		if !retained {
			if err := artifact.Discard(); err != nil {
				result = RemuxResult{}
				returnedErr = errors.Join(returnedErr, err)
			}
		}
	}()

	size, remuxErr := remux(artifact.File())
	if err := verifyInputs(); err != nil {
		return result, err
	}
	if remuxErr != nil {
		return result, remuxErr
	}
	evidence, err := probe(ctx, artifact.File())
	if err != nil {
		return result, err
	}
	if err := validate(evidence); err != nil {
		return result, err
	}
	fingerprint, snapshotSize, err := artifact.Snapshot()
	if err != nil {
		return result, err
	}
	if size <= 0 || size != snapshotSize {
		return result, fmt.Errorf("remux output size changed after probing")
	}
	if err := artifact.Retain(); err != nil {
		return result, err
	}
	retained = true
	return RemuxResult{Fingerprint: fingerprint, SizeBytes: snapshotSize, Evidence: evidence}, nil
}

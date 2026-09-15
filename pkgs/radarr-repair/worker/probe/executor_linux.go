package workerprobe

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/ffprobe"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
)

type MediaFiles interface {
	Open(string, []string, string) (*os.File, error)
	Verify(*os.File, string) error
}

type MediaProber interface {
	ProbeFile(context.Context, *os.File) (controller.ProbeEvidence, error)
}

var (
	_ MediaFiles  = (*mediafile.RootSet)(nil)
	_ MediaProber = (*ffprobe.Runner)(nil)
)

type Executor struct {
	files  MediaFiles
	prober MediaProber
}

func NewExecutor(files MediaFiles, prober MediaProber) (*Executor, error) {
	if files == nil {
		return nil, fmt.Errorf("media file access is required")
	}
	if prober == nil {
		return nil, fmt.Errorf("media prober is required")
	}
	return &Executor{files: files, prober: prober}, nil
}

func (executor *Executor) Execute(
	ctx context.Context,
	request workercontracts.ProbeRequestV1,
) workercontracts.ProbeResponseV1 {
	if err := ctx.Err(); err != nil {
		return FailureResponse(request.RequestID, reasonForError(err))
	}

	media, err := executor.files.Open(
		request.RootID,
		request.PathComponents,
		request.ExpectedFingerprint,
	)
	if err != nil {
		return FailureResponse(request.RequestID, reasonForError(err))
	}
	if media == nil {
		return FailureResponse(request.RequestID, workercontracts.InternalError)
	}
	defer media.Close()

	evidence, probeErr := executor.prober.ProbeFile(ctx, media)
	if err := executor.files.Verify(media, request.ExpectedFingerprint); err != nil {
		return FailureResponse(request.RequestID, reasonForError(err))
	}
	if probeErr != nil {
		return FailureResponse(request.RequestID, reasonForError(probeErr))
	}
	if err := ctx.Err(); err != nil {
		return FailureResponse(request.RequestID, reasonForError(err))
	}
	return SuccessResponse(request.RequestID, evidence)
}

func reasonForError(err error) workercontracts.Reason {
	var fileFailure *mediafile.Failure
	if errors.As(err, &fileFailure) {
		switch fileFailure.Kind {
		case mediafile.FailureUnknownRoot:
			return workercontracts.UnknownRoot
		case mediafile.FailureInvalidPath:
			return workercontracts.InvalidPath
		case mediafile.FailureFileUnavailable:
			return workercontracts.FileUnavailable
		case mediafile.FailureNotRegularFile:
			return workercontracts.NotRegularFile
		case mediafile.FailureFingerprintMismatch:
			return workercontracts.FingerprintMismatch
		default:
			return workercontracts.InternalError
		}
	}

	var probeFailure *ffprobe.Failure
	if errors.As(err, &probeFailure) {
		switch probeFailure.Kind {
		case ffprobe.FailureTimeout:
			return workercontracts.Timeout
		case ffprobe.FailureExecution:
			return workercontracts.ProbeError
		case ffprobe.FailureInvalidOutput:
			return workercontracts.InvalidOutput
		default:
			return workercontracts.InternalError
		}
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return workercontracts.Timeout
	}
	return workercontracts.InternalError
}

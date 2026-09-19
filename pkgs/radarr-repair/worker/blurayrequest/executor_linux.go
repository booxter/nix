package blurayrequest

import (
	"context"
	"errors"
	"fmt"

	"github.com/booxter/nix-config/radarr-repair/internal/ffprobe"
	"github.com/booxter/nix-config/radarr-repair/internal/mkvmerge"
	"github.com/booxter/nix-config/radarr-repair/worker/bluraystage"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/mediaevidence"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
	"github.com/booxter/nix-config/radarr-repair/worker/mediaremux"
)

type Stager interface {
	StageOrRecover(context.Context, bluraystage.Specification) (bluraystage.Result, error)
}

type Executor struct{ stager Stager }

var _ Stager = (*bluraystage.Executor)(nil)

func NewExecutor(stager Stager) (*Executor, error) {
	if stager == nil {
		return nil, fmt.Errorf("Blu-ray remux stager is required")
	}
	return &Executor{stager: stager}, nil
}

func (executor *Executor) Execute(
	ctx context.Context,
	request workercontracts.BlurayRemuxRequestV1,
) workercontracts.BlurayRemuxResponseV1 {
	if executor == nil || ctx == nil {
		return failure(request.RequestID, "internal_error")
	}
	result, err := executor.stager.StageOrRecover(ctx, specification(request))
	if err != nil {
		return failure(request.RequestID, failureReason(err))
	}
	return workercontracts.BlurayRemuxResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.BlurayRemuxSuccessV1{
			SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
			Operation:           workercontracts.StageBlurayRemuxV1,
			RequestID:           request.RequestID,
			Status:              workercontracts.Ok,
			ArtifactID:          result.ArtifactID,
			ArtifactFingerprint: result.Fingerprint,
			SizeBytes:           result.SizeBytes,
			Evidence:            mediaevidence.FromProbe(result.Evidence),
		},
	}
}

func specification(request workercontracts.BlurayRemuxRequestV1) bluraystage.Specification {
	clips := make([]bluraystage.Source, 0, len(request.Clips))
	for _, clip := range request.Clips {
		clips = append(clips, source(clip))
	}
	tracks := make([]mkvmerge.Track, 0, len(request.ExpectedTracks))
	for _, track := range request.ExpectedTracks {
		tracks = append(tracks, mkvmerge.Track{
			Kind: string(track.Kind), Codec: track.Codec, Language: track.Language,
		})
	}
	return bluraystage.Specification{
		ExecutionID: request.ExecutionID, CaseID: request.CaseID,
		CapabilityID: request.CapabilityID, RootID: request.RootID,
		Playlist: source(request.Playlist), Clips: clips,
		ExpectedDurationMS:   request.ExpectedDurationMS,
		ExpectedChapterCount: int(request.ExpectedChapterCount),
		ExpectedTracks:       tracks,
	}
}

func source(source workercontracts.BlurayRemuxSourceV1) bluraystage.Source {
	return bluraystage.Source{
		PathComponents:      append([]string(nil), source.PathComponents...),
		ExpectedFingerprint: source.ExpectedFingerprint,
		SizeBytes:           source.SizeBytes,
	}
}

func failure(
	requestID string,
	reason workercontracts.BlurayRemuxFailureResponseV1Reason,
) workercontracts.BlurayRemuxResponseV1 {
	return workercontracts.BlurayRemuxResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.BlurayRemuxFailureV1{
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Operation:     workercontracts.StageBlurayRemuxV1,
			RequestID:     requestID,
			Status:        workercontracts.Failed,
			Reason:        reason,
		},
	}
}

func failureReason(err error) workercontracts.BlurayRemuxFailureResponseV1Reason {
	var file *mediafile.Failure
	if errors.As(err, &file) {
		switch file.Kind {
		case mediafile.FailureUnknownRoot:
			return "unknown_root"
		case mediafile.FailureInvalidPath:
			return "invalid_path"
		case mediafile.FailureFileUnavailable, mediafile.FailureNotRegularFile:
			return "file_unavailable"
		case mediafile.FailureFingerprintMismatch:
			return "fingerprint_mismatch"
		case mediafile.FailureInsufficientSpace:
			return "insufficient_space"
		case mediafile.FailureArtifactExists:
			return "execution_conflict"
		}
	}
	var remux *mediaremux.Failure
	if errors.As(err, &remux) {
		switch remux.Kind {
		case mediaremux.FailureTimeout:
			return "timeout"
		case mediaremux.FailureInvalidOutput:
			return "invalid_output"
		default:
			return "remux_error"
		}
	}
	var probe *ffprobe.Failure
	if errors.As(err, &probe) {
		if probe.Kind == ffprobe.FailureTimeout {
			return "timeout"
		}
		return "probe_error"
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	return "internal_error"
}

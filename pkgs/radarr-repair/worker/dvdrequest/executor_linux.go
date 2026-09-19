package dvdrequest

import (
	"context"
	"errors"
	"fmt"

	"github.com/booxter/nix-config/radarr-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/radarr-repair/internal/ffprobe"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/dvdremux"
	"github.com/booxter/nix-config/radarr-repair/worker/dvdstage"
	"github.com/booxter/nix-config/radarr-repair/worker/mediaevidence"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
)

type Stager interface {
	StageOrRecover(context.Context, dvdstage.Specification) (dvdstage.Result, error)
}

type Executor struct{ stager Stager }

var _ Stager = (*dvdstage.Executor)(nil)

func NewExecutor(stager Stager) (*Executor, error) {
	if stager == nil {
		return nil, fmt.Errorf("DVD remux stager is required")
	}
	return &Executor{stager: stager}, nil
}

func (executor *Executor) Execute(
	ctx context.Context, request workercontracts.DVDRemuxRequestV1,
) workercontracts.DVDRemuxResponseV1 {
	if executor == nil || ctx == nil {
		return failure(request.RequestID, "internal_error")
	}
	result, err := executor.stager.StageOrRecover(ctx, Specification(request))
	if err != nil {
		return failure(request.RequestID, failureReason(err))
	}
	return workercontracts.DVDRemuxResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.DVDRemuxSuccessV1{
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Operation:     workercontracts.StageDVDRemuxV1,
			RequestID:     request.RequestID, Status: workercontracts.Ok,
			ArtifactID: result.ArtifactID, ArtifactFingerprint: result.Fingerprint,
			SizeBytes: result.SizeBytes, Evidence: mediaevidence.FromProbe(result.Evidence),
		},
	}
}

func Specification(request workercontracts.DVDRemuxRequestV1) dvdstage.Specification {
	sources := make([]dvdstage.Source, 0, len(request.Sources))
	for _, source := range request.Sources {
		sources = append(sources, convertSource(source))
	}
	tracks := make([]dvdvideo.Track, 0, len(request.ExpectedTracks))
	for _, track := range request.ExpectedTracks {
		tracks = append(tracks, dvdvideo.Track{
			Kind: string(track.Kind), Codec: track.Codec, Language: track.Language,
		})
	}
	return dvdstage.Specification{
		ExecutionID: request.ExecutionID, CaseID: request.CaseID,
		CapabilityID: request.CapabilityID, RootID: request.RootID,
		Navigation: convertSource(request.Navigation), Sources: sources,
		TitleNumber:          int(request.TitleNumber),
		ExpectedDurationMS:   request.ExpectedDurationMS,
		ExpectedChapterCount: int(request.ExpectedChapterCount),
		ExpectedTracks:       tracks,
	}
}

func convertSource(source workercontracts.DVDRemuxSourceV1) dvdstage.Source {
	return dvdstage.Source{
		PathComponents:      append([]string(nil), source.PathComponents...),
		ExpectedFingerprint: source.ExpectedFingerprint, SizeBytes: source.SizeBytes,
	}
}

func failure(requestID string, reason workercontracts.BlurayRemuxFailureResponseV1Reason) workercontracts.DVDRemuxResponseV1 {
	return workercontracts.DVDRemuxResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.DVDRemuxFailureV1{
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Operation:     workercontracts.StageDVDRemuxV1,
			RequestID:     requestID, Status: workercontracts.Failed, Reason: reason,
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
	var remux *dvdremux.Failure
	if errors.As(err, &remux) {
		switch remux.Kind {
		case dvdremux.FailureTimeout:
			return "timeout"
		case dvdremux.FailureInvalidOutput:
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

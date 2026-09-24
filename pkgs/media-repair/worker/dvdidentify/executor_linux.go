package dvdidentify

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
)

type MediaFiles interface {
	Open(string, []string, string) (*os.File, error)
	Verify(*os.File, string) error
	AbsolutePath(string, []string) (string, error)
}

type Executor struct {
	files      MediaFiles
	identifier dvdvideo.Identifier
}

func NewExecutor(files MediaFiles, identifier dvdvideo.Identifier) (*Executor, error) {
	if files == nil || identifier == nil {
		return nil, fmt.Errorf("DVD file access and identifier are required")
	}
	return &Executor{files: files, identifier: identifier}, nil
}

func (executor *Executor) Execute(
	ctx context.Context, request workercontracts.DVDIdentifyRequestV1,
) workercontracts.DVDIdentifyResponseV1 {
	if ctx.Err() != nil {
		return failure(request.RequestID, "timeout")
	}
	parts := request.PathComponents
	if len(parts) < 2 || parts[len(parts)-2] != "VIDEO_TS" || parts[len(parts)-1] != "VIDEO_TS.IFO" {
		return failure(request.RequestID, "invalid_path")
	}
	media, err := executor.files.Open(request.RootID, parts, request.ExpectedFingerprint)
	if err != nil {
		return failure(request.RequestID, reasonForError(err))
	}
	defer media.Close()
	path, err := executor.files.AbsolutePath(request.RootID, parts)
	if err != nil {
		return failure(request.RequestID, reasonForError(err))
	}
	titles, identifyErr := executor.identifier.IdentifyDVD(ctx, dvdvideo.Target{
		NavigationPath: path, ExpectedFingerprint: request.ExpectedFingerprint,
	})
	if err := executor.files.Verify(media, request.ExpectedFingerprint); err != nil {
		return failure(request.RequestID, reasonForError(err))
	}
	fresh, err := executor.files.Open(request.RootID, parts, request.ExpectedFingerprint)
	if err != nil {
		return failure(request.RequestID, reasonForError(err))
	}
	_ = fresh.Close()
	if identifyErr != nil {
		if ctx.Err() != nil {
			return failure(request.RequestID, "timeout")
		}
		return failure(request.RequestID, "identification_error")
	}
	result := make([]workercontracts.DVDTitleV1, 0, len(titles))
	for _, title := range titles {
		tracks := make([]workercontracts.DVDTrackV1, 0, len(title.Tracks))
		for _, track := range title.Tracks {
			var language *string
			if track.Language != "" {
				language = &track.Language
			}
			tracks = append(tracks, workercontracts.DVDTrackV1{
				Kind: workercontracts.TrackKind(track.Kind), Codec: track.Codec,
				Language: language,
			})
		}
		result = append(result, workercontracts.DVDTitleV1{
			Number: int64(title.Number), DurationMS: title.DurationMS,
			ChapterCount: int64(title.Chapters), AngleCount: int64(title.Angles),
			TitleSet: int64(title.TitleSet), TitleInSet: int64(title.TitleInSet),
			Tracks: tracks,
		})
	}
	return workercontracts.DVDIdentifyResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.DVDIdentifySuccessV1{
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Operation:     workercontracts.IdentifyDVDV1,
			RequestID:     request.RequestID, Status: workercontracts.Ok,
			Titles: result,
		},
	}
}

func failure(requestID string, reason workercontracts.BlurayIdentifyFailureResponseV1Reason) workercontracts.DVDIdentifyResponseV1 {
	return workercontracts.DVDIdentifyResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.DVDIdentifyFailureV1{
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Operation:     workercontracts.IdentifyDVDV1,
			RequestID:     requestID, Status: workercontracts.Failed,
			Reason: reason,
		},
	}
}

func reasonForError(err error) workercontracts.BlurayIdentifyFailureResponseV1Reason {
	var fileFailure *mediafile.Failure
	if errors.As(err, &fileFailure) {
		switch fileFailure.Kind {
		case mediafile.FailureUnknownRoot:
			return "unknown_root"
		case mediafile.FailureInvalidPath:
			return "invalid_path"
		case mediafile.FailureFileUnavailable:
			return "file_unavailable"
		case mediafile.FailureNotRegularFile:
			return "not_regular_file"
		case mediafile.FailureFingerprintMismatch:
			return "fingerprint_mismatch"
		}
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	return "internal_error"
}

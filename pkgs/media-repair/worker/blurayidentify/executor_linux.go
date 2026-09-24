package blurayidentify

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
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
	identifier mkvmerge.Identifier
}

func NewExecutor(files MediaFiles, identifier mkvmerge.Identifier) (*Executor, error) {
	if files == nil || identifier == nil {
		return nil, fmt.Errorf("Blu-ray file access and identifier are required")
	}
	return &Executor{files: files, identifier: identifier}, nil
}

func (executor *Executor) Execute(
	ctx context.Context,
	request workercontracts.BlurayIdentifyRequestV1,
) workercontracts.BlurayIdentifyResponseV1 {
	if err := ctx.Err(); err != nil {
		return failure(request.RequestID, workercontracts.BlurayIdentifyFailureResponseV1Reason("timeout"))
	}
	parts := request.PathComponents
	if len(parts) < 3 || parts[len(parts)-3] != "BDMV" ||
		parts[len(parts)-2] != "PLAYLIST" || !mkvmerge.NumberedPlaylist(parts[len(parts)-1]) {
		return failure(request.RequestID, workercontracts.BlurayIdentifyFailureResponseV1Reason("invalid_path"))
	}

	media, err := executor.files.Open(
		request.RootID, parts, request.ExpectedFingerprint,
	)
	if err != nil {
		return failure(request.RequestID, reasonForError(err))
	}
	defer media.Close()
	path, err := executor.files.AbsolutePath(request.RootID, parts)
	if err != nil {
		return failure(request.RequestID, reasonForError(err))
	}
	details, identifyErr := executor.identifier.Identify(ctx, mkvmerge.Target{
		Path: path, ExpectedFingerprint: request.ExpectedFingerprint,
	})
	if err := executor.files.Verify(media, request.ExpectedFingerprint); err != nil {
		return failure(request.RequestID, reasonForError(err))
	}
	// Reopen the name as well: mkvmerge needs a path to resolve sibling clips.
	// The first descriptor alone would miss a path replacement during parsing.
	fresh, err := executor.files.Open(request.RootID, parts, request.ExpectedFingerprint)
	if err != nil {
		return failure(request.RequestID, reasonForError(err))
	}
	_ = fresh.Close()
	if identifyErr != nil {
		if ctx.Err() != nil {
			return failure(request.RequestID, workercontracts.BlurayIdentifyFailureResponseV1Reason("timeout"))
		}
		return failure(request.RequestID, workercontracts.BlurayIdentifyFailureResponseV1Reason("identification_error"))
	}
	clipNames, tracks, err := wireDetails(path, details)
	if err != nil {
		return failure(request.RequestID, workercontracts.BlurayIdentifyFailureResponseV1Reason("invalid_output"))
	}
	return workercontracts.BlurayIdentifyResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.BlurayIdentifySuccessV1{
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Operation:     workercontracts.IdentifyBlurayV1,
			RequestID:     request.RequestID,
			Status:        workercontracts.Ok,
			DurationMS:    details.DurationMS,
			ChapterCount:  int64(details.Chapters),
			ClipNames:     clipNames,
			Tracks:        tracks,
		},
	}
}

func wireDetails(path string, details mkvmerge.Playlist) ([]string, []workercontracts.Track, error) {
	streamDir := filepath.Join(filepath.Dir(filepath.Dir(path)), "STREAM")
	if len(details.ClipPaths) == 0 || len(details.Tracks) == 0 || len(details.Tracks) > 32 {
		return nil, nil, fmt.Errorf("Blu-ray identification is incomplete")
	}
	clipNames := make([]string, 0, len(details.ClipPaths))
	for _, clipPath := range details.ClipPaths {
		name := filepath.Base(clipPath)
		if !mkvmerge.NumberedClip(name) || clipPath != filepath.Join(streamDir, name) {
			return nil, nil, fmt.Errorf("Blu-ray clip is outside its stream directory")
		}
		clipNames = append(clipNames, name)
	}
	tracks := make([]workercontracts.Track, 0, len(details.Tracks))
	for _, track := range details.Tracks {
		if len(track.Codec) == 0 || len(track.Codec) > 128 || len(track.Language) > 32 ||
			(track.Kind != "video" && track.Kind != "audio" && track.Kind != "subtitles") {
			return nil, nil, fmt.Errorf("Blu-ray track metadata is invalid")
		}
		var language *string
		if track.Language != "" {
			language = &track.Language
		}
		tracks = append(tracks, workercontracts.Track{
			Kind: workercontracts.TrackKind(track.Kind), Codec: track.Codec,
			Language: language,
		})
	}
	return clipNames, tracks, nil
}

func failure(
	requestID string,
	reason workercontracts.BlurayIdentifyFailureResponseV1Reason,
) workercontracts.BlurayIdentifyResponseV1 {
	return workercontracts.BlurayIdentifyResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.BlurayIdentifyFailureV1{
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Operation:     workercontracts.IdentifyBlurayV1,
			RequestID:     requestID,
			Status:        workercontracts.Failed,
			Reason:        reason,
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

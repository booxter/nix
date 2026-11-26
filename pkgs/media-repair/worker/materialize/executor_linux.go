package materialize

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/worker/cuesheet"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
)

const (
	maximumEntries    = 4096
	maximumFileBytes  = 8 << 30
	maximumTotalBytes = 32 << 30
)

var errWorkspace = errors.New("materialization workspace error")

var audioExtensions = map[string]struct{}{
	".flac": {}, ".wav": {}, ".ape": {}, ".wv": {}, ".wvp": {}, ".m4a": {},
	".mp3": {}, ".ogg": {}, ".opus": {},
}

var videoExtensions = map[string]struct{}{
	".ts": {}, ".m2ts": {}, ".mp4": {}, ".mkv": {}, ".avi": {},
}

type Files interface {
	Open(string, []string, string) (*os.File, error)
	OpenDirectory(string, []string) (*os.File, error)
	Path(string) (string, error)
	Verify(*os.File, string) error
}

type Prober interface {
	Probe(context.Context, string) (controller.ProbeEvidence, error)
}

type RARExtractor interface {
	Extract(context.Context, *os.File, string) error
}

type CueHandler interface {
	Inspect(context.Context, *os.File) (cuesheet.Plan, error)
	InspectEmbedded(context.Context, *os.File) (cuesheet.Plan, bool, error)
	Split(context.Context, *os.File, cuesheet.Plan, string) ([]string, error)
}

type Executor struct {
	files  Files
	prober Prober
	rar    RARExtractor
	cue    CueHandler
}

func NewExecutor(files Files, prober Prober, rar RARExtractor, cue CueHandler) (*Executor, error) {
	if files == nil || prober == nil {
		return nil, fmt.Errorf("materialization requires media access and probing")
	}
	return &Executor{files: files, prober: prober, rar: rar, cue: cue}, nil
}

func (request Request) fail(reason string) Response {
	return Response{Status: "failed", Failure: &Failure{
		SchemaVersion: SchemaVersion, RequestID: request.RequestID,
		Operation: request.Operation, Reason: reason,
	}}
}

func appendCopy(base []string, values ...string) []string {
	result := make([]string, 0, len(base)+len(values))
	result = append(result, base...)
	return append(result, values...)
}

func reasonForError(err error) string {
	switch {
	case errors.Is(err, errWorkspace):
		return "workspace_error"
	case errors.Is(err, errRAREncrypted):
		return FailureEncryptedArchive
	case errors.Is(err, errRARExtract):
		return "extract_failed"
	default:
		return sourceFailureReason(err, FailureInvalidArchive)
	}
}

func sourceFailureReason(err error, fallback string) string {
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
	return fallback
}

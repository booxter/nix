package ffprobe

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/commanddiagnostics"
	"github.com/booxter/nix-config/media-repair/internal/controller"
)

type FailureKind string

const (
	FailureTimeout       FailureKind = "timeout"
	FailureExecution     FailureKind = "probe_error"
	FailureInvalidOutput FailureKind = "invalid_output"
)

type Failure struct {
	Kind        FailureKind
	Diagnostics commanddiagnostics.Diagnostics
	cause       error
}

func (failure *Failure) Error() string {
	switch failure.Kind {
	case FailureTimeout:
		return "ffprobe timed out"
	case FailureExecution:
		return "ffprobe failed"
	case FailureInvalidOutput:
		return "ffprobe returned invalid output"
	default:
		return "ffprobe failed with an unknown error"
	}
}

func (failure *Failure) Unwrap() error {
	return failure.cause
}

type Runner struct {
	executable string
	timeout    time.Duration
}

func NewRunner(executable string, timeout time.Duration) (*Runner, error) {
	if executable == "" || strings.ContainsRune(executable, '\x00') ||
		!filepath.IsAbs(executable) || filepath.Clean(executable) != executable {
		return nil, fmt.Errorf("ffprobe executable must be an absolute clean path")
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("ffprobe timeout must be positive")
	}
	return &Runner{executable: executable, timeout: timeout}, nil
}

func (runner *Runner) Probe(
	ctx context.Context,
	mediaPath string,
) (controller.ProbeEvidence, error) {
	if mediaPath == "" || strings.ContainsRune(mediaPath, '\x00') ||
		!filepath.IsAbs(mediaPath) || filepath.Clean(mediaPath) != mediaPath {
		return controller.ProbeEvidence{}, fmt.Errorf("media path must be an absolute clean path")
	}
	if err := validateProbe(ctx, runner); err != nil {
		return controller.ProbeEvidence{}, err
	}

	media, err := os.Open(mediaPath)
	if err != nil {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureExecution, cause: err}
	}
	defer media.Close()
	return runner.ProbeFile(ctx, media)
}

// ProbeFile probes media through an inherited descriptor without reopening its
// pathname. The caller retains ownership of media.
func (runner *Runner) ProbeFile(
	ctx context.Context,
	media *os.File,
) (controller.ProbeEvidence, error) {
	if err := validateProbe(ctx, runner); err != nil {
		return controller.ProbeEvidence{}, err
	}
	if media == nil {
		return controller.ProbeEvidence{}, fmt.Errorf("media file is required")
	}
	if _, err := media.Seek(0, io.SeekStart); err != nil {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureExecution, cause: err}
	}

	probeContext, cancel := context.WithTimeout(ctx, runner.timeout)
	defer cancel()
	stdout := boundedBuffer{limit: MaxDocumentBytes}
	command := exec.CommandContext(
		probeContext,
		runner.executable,
		"-hide_banner",
		"-loglevel", "error",
		"-bitexact",
		"-output_format", "json=string_validation=fail",
		"-show_format",
		"-show_streams",
		"-show_programs",
		"-show_chapters",
		"-show_entries", requestedEntries(),
		"-protocol_whitelist", "fd",
		"-fd", "3",
		"-i", "fd:",
	)
	// pipe: is not seekable, so inherit the open file and use FFmpeg's fd
	// protocol for containers that require random access.
	command.ExtraFiles = []*os.File{media}
	command.Stdout = &stdout
	diagnosticOutput := commanddiagnostics.NewRecorder()
	command.Stderr = diagnosticOutput
	if err := command.Run(); err != nil {
		diagnostics := diagnosticOutput.Diagnostics()
		if ctx.Err() != nil {
			return controller.ProbeEvidence{}, commanddiagnostics.Attach(ctx.Err(), diagnostics)
		}
		if errors.Is(probeContext.Err(), context.DeadlineExceeded) {
			return controller.ProbeEvidence{}, &Failure{Kind: FailureTimeout,
				Diagnostics: diagnostics, cause: commanddiagnostics.Attach(err, diagnostics)}
		}
		return controller.ProbeEvidence{}, &Failure{Kind: FailureExecution,
			Diagnostics: diagnostics, cause: commanddiagnostics.Attach(err, diagnostics)}
	}
	diagnostics := diagnosticOutput.Diagnostics()
	if stdout.overflow {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureInvalidOutput,
			Diagnostics: diagnostics, cause: commanddiagnostics.Attach(nil, diagnostics)}
	}

	document, err := Decode(stdout.Bytes())
	if err != nil {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureInvalidOutput,
			Diagnostics: diagnostics, cause: commanddiagnostics.Attach(err, diagnostics)}
	}
	evidence, err := Normalize(document)
	if err != nil {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureInvalidOutput,
			Diagnostics: diagnostics, cause: commanddiagnostics.Attach(err, diagnostics)}
	}
	return evidence, nil
}

func validateProbe(ctx context.Context, runner *Runner) error {
	if runner == nil || runner.executable == "" || runner.timeout <= 0 {
		return fmt.Errorf("ffprobe runner is not configured")
	}
	return ctx.Err()
}

func requestedEntries() string {
	return strings.Join([]string{
		sectionEntries(
			"format",
			"nb_streams",
			"nb_programs",
			"format_name",
			"format_long_name",
			"start_time",
			"duration",
			"size",
			"bit_rate",
			"probe_score",
		),
		sectionEntries("format_tags", "title", "encoder", "creation_time"),
		sectionEntries(
			"stream",
			"index",
			"codec_name",
			"codec_long_name",
			"profile",
			"codec_type",
			"codec_tag_string",
			"width",
			"height",
			"pix_fmt",
			"sample_fmt",
			"sample_rate",
			"channels",
			"channel_layout",
			"r_frame_rate",
			"avg_frame_rate",
			"time_base",
			"start_pts",
			"start_time",
			"duration_ts",
			"duration",
			"bit_rate",
			"nb_frames",
		),
		sectionEntries(
			"stream_disposition",
			"default",
			"forced",
			"hearing_impaired",
			"visual_impaired",
		),
		sectionEntries(
			"stream_tags",
			"language",
			"title",
			"handler_name",
			"encoder",
			"creation_time",
		),
		sectionEntries(
			"program",
			"program_id",
			"program_num",
			"nb_streams",
			"pmt_pid",
			"pcr_pid",
		),
		sectionEntries("program_stream", "index"),
		// The top-level stream selectors also apply to streams repeated inside a
		// program. Suppress their child sections, which we do not use.
		sectionEntries("program_stream_disposition"),
		sectionEntries("program_stream_tags"),
		sectionEntries("program_tags", "service_name", "service_provider"),
		sectionEntries(
			"chapter",
			"id",
			"time_base",
			"start",
			"start_time",
			"end",
			"end_time",
		),
		sectionEntries("chapter_tags", "title", "language"),
	}, ":")
}

func sectionEntries(section string, fields ...string) string {
	return section + "=" + strings.Join(fields, ",")
}

type boundedBuffer struct {
	buffer   bytes.Buffer
	limit    int
	overflow bool
}

func (buffer *boundedBuffer) Write(data []byte) (int, error) {
	written := len(data)
	remaining := buffer.limit - buffer.buffer.Len()
	if remaining <= 0 {
		buffer.overflow = true
		return written, nil
	}
	if len(data) > remaining {
		buffer.overflow = true
		data = data[:remaining]
	}
	_, _ = buffer.buffer.Write(data)
	return written, nil
}

func (buffer *boundedBuffer) Bytes() []byte {
	return buffer.buffer.Bytes()
}

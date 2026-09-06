package ffprobe

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

var _ controller.MediaProbeReader = (*Runner)(nil)

type FailureKind string

const (
	FailureTimeout       FailureKind = "timeout"
	FailureExecution     FailureKind = "probe_error"
	FailureInvalidOutput FailureKind = "invalid_output"
)

type Failure struct {
	Kind  FailureKind
	cause error
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
	if runner == nil || runner.executable == "" || runner.timeout <= 0 {
		return controller.ProbeEvidence{}, fmt.Errorf("ffprobe runner is not configured")
	}
	if mediaPath == "" || strings.ContainsRune(mediaPath, '\x00') ||
		!filepath.IsAbs(mediaPath) || filepath.Clean(mediaPath) != mediaPath {
		return controller.ProbeEvidence{}, fmt.Errorf("media path must be an absolute clean path")
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
		"-protocol_whitelist", "file",
		"-i", mediaPath,
	)
	command.Stdout = &stdout
	// ffprobe diagnostics can contain the absolute media path. The typed failure
	// is sufficient here and cannot accidentally cross the planner boundary.
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		if ctx.Err() != nil {
			return controller.ProbeEvidence{}, ctx.Err()
		}
		if errors.Is(probeContext.Err(), context.DeadlineExceeded) {
			return controller.ProbeEvidence{}, &Failure{Kind: FailureTimeout, cause: err}
		}
		return controller.ProbeEvidence{}, &Failure{Kind: FailureExecution, cause: err}
	}
	if stdout.overflow {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureInvalidOutput}
	}

	document, err := Decode(stdout.Bytes())
	if err != nil {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureInvalidOutput, cause: err}
	}
	evidence, err := Normalize(document)
	if err != nil {
		return controller.ProbeEvidence{}, &Failure{Kind: FailureInvalidOutput, cause: err}
	}
	return evidence, nil
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

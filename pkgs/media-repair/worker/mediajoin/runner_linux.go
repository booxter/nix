package mediajoin

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

const (
	firstInheritedDescriptor = 3
	maxDiagnosticBytes       = 64 << 10
	commandWaitDelay         = 5 * time.Second
)

type FailureKind string

const (
	FailureTimeout       FailureKind = "timeout"
	FailureExecution     FailureKind = "join_error"
	FailureInvalidOutput FailureKind = "invalid_output"
)

type Diagnostics struct {
	Text      string
	Truncated bool
}

type Result struct {
	SizeBytes   int64
	Diagnostics Diagnostics
}

type Failure struct {
	Kind        FailureKind
	Diagnostics Diagnostics
	cause       error
}

func (failure *Failure) Error() string {
	switch failure.Kind {
	case FailureTimeout:
		return "media join timed out"
	case FailureExecution:
		return "media join failed"
	case FailureInvalidOutput:
		return "media join produced invalid output"
	default:
		return "media join failed with an unknown error"
	}
}

func (failure *Failure) Unwrap() error {
	return failure.cause
}

type Joiner interface {
	Join(
		context.Context,
		[]*os.File,
		*os.File,
		workercontracts.OutputContainer,
	) (Result, error)
}

type Runner struct {
	executable string
	timeout    time.Duration
}

var _ Joiner = (*Runner)(nil)

func NewRunner(executable string, timeout time.Duration) (*Runner, error) {
	if executable == "" || strings.ContainsRune(executable, '\x00') ||
		!filepath.IsAbs(executable) || filepath.Clean(executable) != executable {
		return nil, fmt.Errorf("ffmpeg executable must be an absolute clean path")
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("media join timeout must be positive")
	}
	return &Runner{executable: executable, timeout: timeout}, nil
}

// Join concatenates parts in the supplied order into an empty output file.
// It neither closes nor removes any caller-owned file.
func (runner *Runner) Join(
	ctx context.Context,
	parts []*os.File,
	output *os.File,
	container workercontracts.OutputContainer,
) (Result, error) {
	format, err := outputFormat(container)
	if err != nil {
		return Result{}, err
	}
	if err := validateRunner(ctx, runner); err != nil {
		return Result{}, err
	}
	if err := prepareFiles(parts, output); err != nil {
		return Result{}, err
	}

	joinContext, cancel := context.WithTimeout(ctx, runner.timeout)
	defer cancel()
	manifest := concatManifest(len(parts))
	outputDescriptor := firstInheritedDescriptor + len(parts)
	arguments := []string{
		"-hide_banner",
		"-loglevel", "warning",
		"-nostdin",
		"-y",
		"-f", "concat",
		"-safe", "0",
		"-protocol_whitelist", "fd,pipe",
		"-i", "pipe:0",
		"-map", "0",
		"-map_metadata", "0",
		"-map_chapters", "0",
		"-copy_unknown",
		"-c", "copy",
		"-f", format,
		"-fd", strconv.Itoa(outputDescriptor),
		"fd:",
	}
	command := exec.CommandContext(joinContext, runner.executable, arguments...)
	command.WaitDelay = commandWaitDelay
	command.Stdin = strings.NewReader(manifest)
	command.Stdout = io.Discard
	command.ExtraFiles = append(append([]*os.File(nil), parts...), output)
	diagnosticOutput := &diagnosticWriter{}
	command.Stderr = diagnosticOutput
	if err := command.Run(); err != nil {
		diagnostics := diagnosticOutput.Diagnostics()
		if ctx.Err() != nil {
			return Result{}, ctx.Err()
		}
		if errors.Is(joinContext.Err(), context.DeadlineExceeded) {
			return Result{}, &Failure{
				Kind: FailureTimeout, Diagnostics: diagnostics, cause: err,
			}
		}
		return Result{}, &Failure{
			Kind: FailureExecution, Diagnostics: diagnostics, cause: err,
		}
	}
	diagnostics := diagnosticOutput.Diagnostics()

	if err := output.Sync(); err != nil {
		return Result{}, &Failure{
			Kind: FailureInvalidOutput, Diagnostics: diagnostics, cause: err,
		}
	}
	info, err := output.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
		return Result{}, &Failure{
			Kind: FailureInvalidOutput, Diagnostics: diagnostics, cause: err,
		}
	}
	if _, err := output.Seek(0, io.SeekStart); err != nil {
		return Result{}, &Failure{
			Kind: FailureInvalidOutput, Diagnostics: diagnostics, cause: err,
		}
	}
	return Result{SizeBytes: info.Size(), Diagnostics: diagnostics}, nil
}

func validateRunner(ctx context.Context, runner *Runner) error {
	if runner == nil || runner.executable == "" || runner.timeout <= 0 {
		return fmt.Errorf("media join runner is not configured")
	}
	return ctx.Err()
}

func outputFormat(container workercontracts.OutputContainer) (string, error) {
	switch container {
	case workercontracts.OutputContainerAVI:
		return "avi", nil
	case workercontracts.OutputContainerMKV:
		return "matroska", nil
	case workercontracts.OutputContainerMP4:
		return "mp4", nil
	default:
		return "", fmt.Errorf("unsupported output container %q", container)
	}
}

func prepareFiles(parts []*os.File, output *os.File) error {
	if len(parts) < 2 {
		return fmt.Errorf("media join requires at least two parts")
	}
	if output == nil {
		return fmt.Errorf("media join output is required")
	}
	outputInfo, err := output.Stat()
	if err != nil {
		return fmt.Errorf("inspect media join output: %w", err)
	}
	if !outputInfo.Mode().IsRegular() || outputInfo.Size() != 0 {
		return fmt.Errorf("media join output must be an empty regular file")
	}

	partInfo := make([]os.FileInfo, len(parts))
	for index, part := range parts {
		if part == nil {
			return fmt.Errorf("media join part %d is required", index)
		}
		info, err := part.Stat()
		if err != nil {
			return fmt.Errorf("inspect media join part %d: %w", index, err)
		}
		if !info.Mode().IsRegular() || info.Size() <= 0 {
			return fmt.Errorf("media join part %d must be a non-empty regular file", index)
		}
		if os.SameFile(info, outputInfo) {
			return fmt.Errorf("media join output aliases part %d", index)
		}
		for previous := 0; previous < index; previous++ {
			if os.SameFile(info, partInfo[previous]) {
				return fmt.Errorf("media join part %d duplicates part %d", index, previous)
			}
		}
		if _, err := part.Seek(0, io.SeekStart); err != nil {
			return fmt.Errorf("seek media join part %d: %w", index, err)
		}
		partInfo[index] = info
	}
	if _, err := output.Seek(0, io.SeekStart); err != nil {
		return fmt.Errorf("seek media join output: %w", err)
	}
	return nil
}

func concatManifest(partCount int) string {
	var manifest strings.Builder
	manifest.WriteString("ffconcat version 1.0\n")
	for index := range partCount {
		// The fd protocol deliberately refuses descriptor numbers in its URL.
		// A per-file concat option binds each inherited descriptor without a path.
		_, _ = fmt.Fprintf(
			&manifest,
			"file fd:\noption fd %d\n",
			firstInheritedDescriptor+index,
		)
	}
	return manifest.String()
}

type diagnosticWriter struct {
	data      []byte
	truncated bool
}

func (writer *diagnosticWriter) Write(data []byte) (int, error) {
	written := len(data)
	remaining := maxDiagnosticBytes - len(writer.data)
	if remaining > 0 {
		writer.data = append(writer.data, data[:min(len(data), remaining)]...)
	}
	if len(data) > remaining {
		writer.truncated = true
	}
	return written, nil
}

func (writer *diagnosticWriter) Diagnostics() Diagnostics {
	return Diagnostics{
		Text:      strings.TrimSpace(string(writer.data)),
		Truncated: writer.truncated,
	}
}

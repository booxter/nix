package mediaremux

import (
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
)

const (
	outputDescriptor = 3
	commandWaitDelay = 5 * time.Second
)

type FailureKind string

const (
	FailureTimeout       FailureKind = "timeout"
	FailureExecution     FailureKind = "remux_error"
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
		return "Blu-ray remux timed out"
	case FailureExecution:
		return "Blu-ray remux failed"
	default:
		return "Blu-ray remux produced invalid output"
	}
}

func (failure *Failure) Unwrap() error { return failure.cause }

type Remuxer interface {
	Remux(context.Context, string, *os.File) (int64, error)
}

type Runner struct {
	executable string
	timeout    time.Duration
}

var _ Remuxer = (*Runner)(nil)

func NewRunner(executable string, timeout time.Duration) (*Runner, error) {
	if executable == "" || strings.ContainsRune(executable, '\x00') ||
		!filepath.IsAbs(executable) || filepath.Clean(executable) != executable {
		return nil, fmt.Errorf("mkvmerge executable must be an absolute clean path")
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("Blu-ray remux timeout must be positive")
	}
	return &Runner{executable: executable, timeout: timeout}, nil
}

// Remux writes into a caller-owned, empty regular file. The output descriptor
// is inherited by mkvmerge, so it cannot replace the staged file by name.
func (runner *Runner) Remux(
	ctx context.Context,
	playlistPath string,
	output *os.File,
) (int64, error) {
	if runner == nil || runner.executable == "" || runner.timeout <= 0 {
		return 0, fmt.Errorf("Blu-ray remux runner is not configured")
	}
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	if playlistPath == "" || strings.ContainsRune(playlistPath, '\x00') ||
		!filepath.IsAbs(playlistPath) || filepath.Clean(playlistPath) != playlistPath {
		return 0, fmt.Errorf("Blu-ray playlist path must be absolute and clean")
	}
	if output == nil {
		return 0, fmt.Errorf("Blu-ray remux output is required")
	}
	info, err := output.Stat()
	if err != nil {
		return 0, fmt.Errorf("inspect Blu-ray remux output: %w", err)
	}
	if !info.Mode().IsRegular() || info.Size() != 0 {
		return 0, fmt.Errorf("Blu-ray remux output must be an empty regular file")
	}

	remuxContext, cancel := context.WithTimeout(ctx, runner.timeout)
	defer cancel()
	command := exec.CommandContext(
		remuxContext,
		runner.executable,
		"--quiet", "--abort-on-warnings", "--no-date",
		"--output", fmt.Sprintf("/proc/self/fd/%d", outputDescriptor),
		playlistPath,
	)
	command.WaitDelay = commandWaitDelay
	diagnosticOutput := commanddiagnostics.NewRecorder(playlistPath)
	command.Stdout = diagnosticOutput
	command.Stderr = diagnosticOutput
	command.ExtraFiles = []*os.File{output}
	if err := command.Run(); err != nil {
		diagnostics := diagnosticOutput.Diagnostics()
		if ctx.Err() != nil {
			return 0, commanddiagnostics.Attach(ctx.Err(), diagnostics)
		}
		if errors.Is(remuxContext.Err(), context.DeadlineExceeded) {
			return 0, &Failure{Kind: FailureTimeout, Diagnostics: diagnostics,
				cause: commanddiagnostics.Attach(err, diagnostics)}
		}
		return 0, &Failure{Kind: FailureExecution, Diagnostics: diagnostics,
			cause: commanddiagnostics.Attach(err, diagnostics)}
	}
	if err := output.Sync(); err != nil {
		return 0, &Failure{Kind: FailureInvalidOutput, cause: err}
	}
	info, err = output.Stat()
	if err != nil {
		return 0, &Failure{Kind: FailureInvalidOutput, cause: err}
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 {
		return 0, &Failure{Kind: FailureInvalidOutput}
	}
	if _, err := output.Seek(0, io.SeekStart); err != nil {
		return 0, &Failure{Kind: FailureInvalidOutput, cause: err}
	}
	return info.Size(), nil
}

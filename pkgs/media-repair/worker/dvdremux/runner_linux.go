package dvdremux

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
)

type FailureKind string

const (
	FailureTimeout       FailureKind = "timeout"
	FailureExecution     FailureKind = "remux_error"
	FailureInvalidOutput FailureKind = "invalid_output"
)

type Failure struct {
	Kind  FailureKind
	cause error
}

func (failure *Failure) Error() string { return "DVD remux " + string(failure.Kind) }
func (failure *Failure) Unwrap() error { return failure.cause }

type Remuxer interface {
	RemuxDVD(context.Context, string, int, *os.File) (int64, error)
}

type Runner struct {
	executable string
	timeout    time.Duration
}

var _ Remuxer = (*Runner)(nil)

func NewRunner(executable string, timeout time.Duration) (*Runner, error) {
	if executable == "" || strings.ContainsRune(executable, '\x00') ||
		!filepath.IsAbs(executable) || filepath.Clean(executable) != executable ||
		timeout <= 0 {
		return nil, fmt.Errorf("DVD remux requires an absolute ffmpeg path and positive timeout")
	}
	return &Runner{executable: executable, timeout: timeout}, nil
}

// RemuxDVD confines FFmpeg output to the caller-owned staged file descriptor.
func (runner *Runner) RemuxDVD(
	ctx context.Context, directory string, title int, output *os.File,
) (int64, error) {
	if runner == nil || runner.executable == "" || runner.timeout <= 0 {
		return 0, fmt.Errorf("DVD remux runner is not configured")
	}
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	if !filepath.IsAbs(directory) || filepath.Clean(directory) != directory ||
		filepath.Base(directory) != "VIDEO_TS" || title < 1 || title > 128 || output == nil {
		return 0, fmt.Errorf("DVD remux requires a VIDEO_TS directory, title, and output")
	}
	info, err := output.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() != 0 {
		return 0, fmt.Errorf("DVD remux output must be an empty regular file")
	}
	remuxContext, cancel := context.WithTimeout(ctx, runner.timeout)
	defer cancel()
	command := exec.CommandContext(remuxContext, runner.executable,
		"-hide_banner", "-nostdin", "-loglevel", "error", "-y",
		"-f", "dvdvideo", "-title", strconv.Itoa(title), "-i", directory,
		"-map", "0:v", "-map", "0:a", "-map", "0:s?",
		"-c", "copy", "-f", "matroska", "/proc/self/fd/3")
	command.WaitDelay = 5 * time.Second
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	command.ExtraFiles = []*os.File{output}
	if err := command.Run(); err != nil {
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		if errors.Is(remuxContext.Err(), context.DeadlineExceeded) {
			return 0, &Failure{Kind: FailureTimeout, cause: err}
		}
		return 0, &Failure{Kind: FailureExecution, cause: err}
	}
	if err := output.Sync(); err != nil {
		return 0, &Failure{Kind: FailureInvalidOutput, cause: err}
	}
	info, err = output.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
		return 0, &Failure{Kind: FailureInvalidOutput, cause: err}
	}
	if _, err := output.Seek(0, io.SeekStart); err != nil {
		return 0, &Failure{Kind: FailureInvalidOutput, cause: err}
	}
	return info.Size(), nil
}

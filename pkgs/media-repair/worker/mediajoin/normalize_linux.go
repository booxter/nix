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

	"github.com/booxter/nix-config/media-repair/internal/commanddiagnostics"
)

func (runner *Runner) normalize(ctx context.Context, parts []*os.File, output *os.File, format string) ([]*os.File, func(), error) {
	// The output lives in the service-owned staging directory. Resolve its
	// descriptor because the storage interface intentionally hides pathnames.
	// Keeping scratch media beside it avoids filling the helper's /tmp tmpfs.
	outputPath, err := os.Readlink(fmt.Sprintf("/proc/self/fd/%d", output.Fd()))
	if err != nil {
		return nil, nil, err
	}
	directory, err := os.MkdirTemp(filepath.Dir(outputPath), ".normalize-")
	if err != nil {
		return nil, nil, err
	}
	var normalized []*os.File
	cleanup := func() {
		for _, file := range normalized {
			_ = file.Close()
		}
		_ = os.RemoveAll(directory)
	}

	for index, part := range parts {
		file, err := os.OpenFile(filepath.Join(directory, strconv.Itoa(index)), os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600)
		if err != nil {
			cleanup()
			return nil, nil, err
		}
		normalized = append(normalized, file)
		if err := runner.remux(ctx, part, file, format); err != nil {
			cleanup()
			return nil, nil, err
		}
	}
	return normalized, cleanup, nil
}

func (runner *Runner) remux(ctx context.Context, source, output *os.File, format string) error {
	arguments := []string{
		"-hide_banner", "-loglevel", "warning", "-nostdin", "-y",
		"-copyts", "-start_at_zero", "-protocol_whitelist", "fd",
		"-fd", "3", "-i", "fd:", "-map", "0", "-map_metadata", "0",
		"-map_chapters", "0", "-copy_unknown", "-c", "copy",
	}
	if format == "mp4" {
		// A shared video timescale is required before the concat demuxer sees
		// the parts. Setting it only on the joined output is too late.
		arguments = append(arguments, "-video_track_timescale", "90000")
	}
	// Keep decoder preroll before the first presentation timestamp inside
	// each part's duration, so adjacent parts cannot overlap that preroll.
	arguments = append(arguments, "-avoid_negative_ts", "make_zero", "-f", format, "-fd", "4", "fd:")
	command := exec.CommandContext(ctx, runner.executable, arguments...)
	command.WaitDelay = commandWaitDelay
	command.ExtraFiles = []*os.File{source, output}
	command.Stdout = io.Discard
	diagnostics := commanddiagnostics.NewRecorder()
	command.Stderr = diagnostics
	if err := command.Run(); err != nil {
		kind := FailureExecution
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			kind = FailureTimeout
		}
		return &Failure{Kind: kind, Diagnostics: diagnostics.Diagnostics(), cause: err}
	}
	_, err := output.Seek(0, io.SeekStart)
	return err
}

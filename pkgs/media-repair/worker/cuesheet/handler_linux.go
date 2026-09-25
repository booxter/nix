package cuesheet

import (
	"bufio"
	"bytes"
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

const (
	MaximumBytes       = 1 << 20
	maximumTracks      = 99
	maximumDiagnostics = 64 << 10
)

var ErrInvalid = errors.New("invalid cue sheet")

type Plan struct {
	Starts []time.Duration
}

type Handler struct {
	cueconvert     string
	cuebreakpoints string
	ffmpeg         string
	wvunpack       string
}

func NewHandler(cueconvert, cuebreakpoints, ffmpeg, wvunpack string) (*Handler, error) {
	for name, executable := range map[string]string{
		"cueconvert": cueconvert, "cuebreakpoints": cuebreakpoints,
		"ffmpeg": ffmpeg, "wvunpack": wvunpack,
	} {
		if executable == "" || !filepath.IsAbs(executable) || filepath.Clean(executable) != executable {
			return nil, fmt.Errorf("%s executable must be an absolute clean path", name)
		}
	}
	return &Handler{
		cueconvert: cueconvert, cuebreakpoints: cuebreakpoints,
		ffmpeg: ffmpeg, wvunpack: wvunpack,
	}, nil
}

func (handler *Handler) InspectEmbedded(ctx context.Context, input *os.File) (Plan, bool, error) {
	if handler == nil || input == nil {
		return Plan{}, false, ErrInvalid
	}
	cue, err := extractWavPackCue(ctx, handler.wvunpack, input)
	if err != nil {
		if ctx.Err() != nil {
			return Plan{}, false, ctx.Err()
		}
		if strings.Contains(err.Error(), `tag "cuesheet" not found`) {
			return Plan{}, false, nil
		}
		return Plan{}, false, fmt.Errorf("%w: extract embedded WavPack cue: %v", ErrInvalid, err)
	}
	if len(cue) == 0 {
		return Plan{}, false, fmt.Errorf("%w: embedded WavPack cue is empty", ErrInvalid)
	}
	temporary, err := os.CreateTemp("", "media-repair-*.cue")
	if err != nil {
		return Plan{}, false, fmt.Errorf("store embedded cue sheet: %w", err)
	}
	name := temporary.Name()
	defer os.Remove(name)
	if _, err := temporary.Write(cue); err != nil {
		_ = temporary.Close()
		return Plan{}, false, fmt.Errorf("store embedded cue sheet: %w", err)
	}
	if _, err := temporary.Seek(0, io.SeekStart); err != nil {
		_ = temporary.Close()
		return Plan{}, false, fmt.Errorf("rewind embedded cue sheet: %w", err)
	}
	plan, inspectErr := handler.Inspect(ctx, temporary)
	closeErr := temporary.Close()
	if inspectErr != nil || closeErr != nil {
		return Plan{}, false, errors.Join(inspectErr, closeErr)
	}
	return plan, true, nil
}

func (handler *Handler) Inspect(ctx context.Context, input *os.File) (Plan, error) {
	if handler == nil || input == nil {
		return Plan{}, ErrInvalid
	}
	toc, err := runCueTool(
		ctx, handler.cueconvert, input, "-i", "cue", "-o", "toc",
	)
	if err != nil {
		return Plan{}, fmt.Errorf("%w: cueconvert: %v", ErrInvalid, err)
	}
	tracks, err := audioTrackCount(toc)
	if err != nil {
		return Plan{}, err
	}
	output, err := runCueTool(
		ctx, handler.cuebreakpoints, input, "-i", "cue", "--append-gaps",
	)
	if err != nil {
		return Plan{}, fmt.Errorf("%w: cuebreakpoints: %v", ErrInvalid, err)
	}
	starts, err := parseBreakpoints(output)
	if err != nil || len(starts) != tracks-1 {
		return Plan{}, fmt.Errorf("%w: breakpoints do not match audio tracks", ErrInvalid)
	}
	return Plan{Starts: append([]time.Duration{0}, starts...)}, nil
}

func audioTrackCount(toc []byte) (int, error) {
	tracks := 0
	scanner := bufio.NewScanner(bytes.NewReader(toc))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "TRACK ") {
			continue
		}
		if line != "TRACK AUDIO" {
			return 0, fmt.Errorf("%w: sheet contains a non-audio track", ErrInvalid)
		}
		tracks++
	}
	if err := scanner.Err(); err != nil {
		return 0, fmt.Errorf("%w: read normalized sheet: %v", ErrInvalid, err)
	}
	if tracks < 2 || tracks > maximumTracks {
		return 0, fmt.Errorf("%w: sheet must contain 2 to %d tracks", ErrInvalid, maximumTracks)
	}
	return tracks, nil
}

func parseBreakpoints(data []byte) ([]time.Duration, error) {
	result := make([]time.Duration, 0)
	previous := time.Duration(0)
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		parts := strings.Split(line, ":")
		if len(parts) != 2 {
			return nil, ErrInvalid
		}
		secondsAndFrames := strings.Split(parts[1], ".")
		if len(secondsAndFrames) != 2 {
			return nil, ErrInvalid
		}
		minutes, minutesErr := strconv.Atoi(parts[0])
		seconds, secondsErr := strconv.Atoi(secondsAndFrames[0])
		frames, framesErr := strconv.Atoi(secondsAndFrames[1])
		if minutesErr != nil || secondsErr != nil || framesErr != nil ||
			minutes < 0 || seconds < 0 || seconds >= 60 || frames < 0 || frames >= 75 {
			return nil, ErrInvalid
		}
		start := time.Duration(minutes)*time.Minute + time.Duration(seconds)*time.Second +
			time.Duration(frames)*time.Second/75
		if start <= previous || len(result) >= maximumTracks-1 {
			return nil, ErrInvalid
		}
		result = append(result, start)
		previous = start
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("%w: read breakpoints: %v", ErrInvalid, err)
	}
	return result, nil
}

func (handler *Handler) Split(
	ctx context.Context,
	input *os.File,
	plan Plan,
	destination string,
) ([]string, error) {
	if handler == nil || input == nil || len(plan.Starts) < 2 ||
		len(plan.Starts) > maximumTracks || !filepath.IsAbs(destination) {
		return nil, ErrInvalid
	}
	outputs := make([]string, 0, len(plan.Starts))
	for index, start := range plan.Starts {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		name := fmt.Sprintf("%02d.flac", index+1)
		output := filepath.Join(destination, name)
		arguments := []string{
			"-nostdin", "-v", "error", "-n", "-i", "/proc/self/fd/3",
			"-map", "0:a:0", "-vn", "-sn", "-dn", "-map_metadata", "-1",
			"-map_chapters", "-1", "-ss", cueTime(start),
		}
		if index+1 < len(plan.Starts) {
			arguments = append(arguments, "-t", cueTime(plan.Starts[index+1]-start))
		}
		arguments = append(arguments, "-c:a", "flac", "-compression_level", "8", output)
		if err := runFFmpeg(ctx, handler.ffmpeg, input, arguments...); err != nil {
			return nil, fmt.Errorf("split cue track %d: %w", index+1, err)
		}
		outputs = append(outputs, name)
	}
	return outputs, nil
}

func cueTime(value time.Duration) string {
	microseconds := value.Microseconds()
	return fmt.Sprintf("%d.%06d", microseconds/1_000_000, microseconds%1_000_000)
}

func runCueTool(
	ctx context.Context,
	executable string,
	input *os.File,
	arguments ...string,
) ([]byte, error) {
	if _, err := input.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	arguments = append(arguments, "/proc/self/fd/3")
	command := exec.CommandContext(ctx, executable, arguments...)
	command.ExtraFiles = []*os.File{input}
	var stdout bytes.Buffer
	stdoutLimit := &limitedWriter{target: &stdout, remaining: MaximumBytes}
	command.Stdout = stdoutLimit
	var stderr bytes.Buffer
	command.Stderr = &limitedWriter{target: &stderr, remaining: maximumDiagnostics}
	if err := command.Run(); err != nil {
		return nil, fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	if stdoutLimit.exceeded {
		return nil, fmt.Errorf("output exceeds limit")
	}
	return stdout.Bytes(), nil
}

func extractWavPackCue(
	ctx context.Context,
	executable string,
	input *os.File,
) ([]byte, error) {
	if _, err := input.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	directory, err := os.MkdirTemp("", "media-repair-wavpack-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(directory)
	filename := filepath.Join(directory, "image.wv")
	if err := os.Symlink("/proc/self/fd/3", filename); err != nil {
		return nil, err
	}
	command := exec.CommandContext(ctx, executable, "-q", "-c", filename)
	command.ExtraFiles = []*os.File{input}
	var stdout bytes.Buffer
	stdoutLimit := &limitedWriter{target: &stdout, remaining: MaximumBytes}
	command.Stdout = stdoutLimit
	var stderr bytes.Buffer
	command.Stderr = &limitedWriter{target: &stderr, remaining: maximumDiagnostics}
	if err := command.Run(); err != nil {
		return nil, fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	if stdoutLimit.exceeded {
		return nil, fmt.Errorf("output exceeds limit")
	}
	return stdout.Bytes(), nil
}

func runFFmpeg(ctx context.Context, executable string, input *os.File, arguments ...string) error {
	if _, err := input.Seek(0, io.SeekStart); err != nil {
		return err
	}
	command := exec.CommandContext(ctx, executable, arguments...)
	command.ExtraFiles = []*os.File{input}
	command.Stdout = io.Discard
	var stderr bytes.Buffer
	command.Stderr = &limitedWriter{target: &stderr, remaining: maximumDiagnostics}
	if err := command.Run(); err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

type limitedWriter struct {
	target    io.Writer
	remaining int64
	exceeded  bool
}

func (writer *limitedWriter) Write(data []byte) (int, error) {
	writable := min(int64(len(data)), writer.remaining)
	if writable > 0 {
		_, _ = writer.target.Write(data[:writable])
		writer.remaining -= writable
	}
	if writable != int64(len(data)) {
		writer.exceeded = true
	}
	return len(data), nil
}

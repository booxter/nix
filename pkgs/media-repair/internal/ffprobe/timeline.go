package ffprobe

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"strconv"

	"github.com/booxter/nix-config/media-repair/internal/commanddiagnostics"
)

// Packet times are seconds, independent of the container's timestamp units.
// Missing timestamps remain NaN; they must not silently become zero.
type Packet struct {
	PTS      float64
	DTS      float64
	Duration float64
}

type Timeline map[int][]Packet

func (runner *Runner) Timeline(ctx context.Context, media *os.File) (Timeline, error) {
	if _, err := media.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	command := exec.CommandContext(ctx, runner.executable,
		"-v", "error", "-show_packets",
		"-show_entries", "packet=stream_index,pts_time,dts_time,duration_time",
		"-of", "json", "-protocol_whitelist", "fd", "-fd", "3", "-i", "fd:",
	)
	command.ExtraFiles = []*os.File{media}
	diagnostics := commanddiagnostics.NewRecorder()
	command.Stderr = diagnostics
	stdout, err := command.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := command.Start(); err != nil {
		return nil, err
	}

	// Decode incrementally: ffprobe's JSON can be much larger than the compact
	// timeline, especially for multichannel audio in a feature-length movie.
	timeline, decodeErr := readTimeline(stdout)
	if decodeErr != nil {
		cancel()
	}
	commandErr := command.Wait()
	if decodeErr != nil {
		return nil, decodeErr
	}
	if commandErr != nil {
		return nil, commanddiagnostics.Attach(commandErr, diagnostics.Diagnostics())
	}
	if len(timeline) == 0 {
		return nil, fmt.Errorf("media contains no timed packets")
	}
	return timeline, nil
}

func readTimeline(input io.Reader) (Timeline, error) {
	decoder := json.NewDecoder(input)
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return nil, fmt.Errorf("invalid packet document: %v", err)
	}
	result := make(Timeline)
	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		if key != "packets" {
			var ignored json.RawMessage
			if err := decoder.Decode(&ignored); err != nil {
				return nil, err
			}
			continue
		}
		if token, err := decoder.Token(); err != nil || token != json.Delim('[') {
			return nil, fmt.Errorf("invalid packet list: %v", err)
		}
		for decoder.More() {
			var packet struct {
				Stream   int    `json:"stream_index"`
				PTS      string `json:"pts_time"`
				DTS      string `json:"dts_time"`
				Duration string `json:"duration_time"`
			}
			if err := decoder.Decode(&packet); err != nil {
				return nil, err
			}
			result[packet.Stream] = append(result[packet.Stream], Packet{
				PTS: packetTime(packet.PTS), DTS: packetTime(packet.DTS),
				Duration: packetTime(packet.Duration),
			})
		}
		if _, err := decoder.Token(); err != nil {
			return nil, err
		}
	}
	if _, err := decoder.Token(); err != nil {
		return nil, err
	}
	return result, nil
}

func packetTime(value string) float64 {
	seconds, err := strconv.ParseFloat(value, 64)
	if err != nil || math.IsInf(seconds, 0) {
		return math.NaN()
	}
	return seconds
}

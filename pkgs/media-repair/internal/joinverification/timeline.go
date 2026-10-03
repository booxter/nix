package joinverification

import (
	"fmt"
	"math"
	"slices"

	"github.com/booxter/nix-config/media-repair/internal/ffprobe"
)

// Matroska rounds timestamps to milliseconds. Two milliseconds allows that
// quantization through remuxing without accepting compressed or stretched scenes.
const timingTolerance = 0.002

func ValidateTimeline(parts []ffprobe.Timeline, output ffprobe.Timeline) error {
	if len(parts) == 0 || len(output) == 0 {
		return fmt.Errorf("packet timing evidence is empty")
	}

	positions := make(map[int]int)
	previousEnd := math.NaN()
	for partIndex, part := range parts {
		if len(part) != len(output) {
			return fmt.Errorf("part %d: stream count changed", partIndex+1)
		}

		streams := make([]int, 0, len(part))
		for stream := range part {
			streams = append(streams, stream)
		}
		slices.Sort(streams)

		offset := math.NaN()
		partStart, partEnd := math.Inf(1), math.Inf(-1)
		for _, stream := range streams {
			source := part[stream]
			start := positions[stream]
			joined := output[stream]
			if len(source) == 0 || len(joined)-start < len(source) {
				return fmt.Errorf("part %d stream %d: missing packets", partIndex+1, stream)
			}

			if math.IsNaN(offset) {
				offset = joined[start].PTS - source[0].PTS
			}
			if math.IsNaN(offset) {
				return fmt.Errorf("part %d stream %d: missing presentation timestamp", partIndex+1, stream)
			}

			first, last, err := validateStreamTiming(source, joined[start:start+len(source)], offset)
			if err != nil {
				return fmt.Errorf("part %d stream %d: %w", partIndex+1, stream, err)
			}
			partStart = math.Min(partStart, first)
			partEnd = math.Max(partEnd, last)
			positions[stream] += len(source)
		}

		// A small codec-frame boundary gap is normal; a displaced whole scene
		// is not. Internal timing is checked much more tightly above.
		if !math.IsNaN(previousEnd) && math.Abs(partStart-previousEnd) > 0.1 {
			return fmt.Errorf("part %d: boundary gap or overlap of %.6f seconds", partIndex+1, partStart-previousEnd)
		}
		previousEnd = partEnd
	}

	for stream, packets := range output {
		if positions[stream] != len(packets) {
			return fmt.Errorf("stream %d: unexpected extra packets", stream)
		}
	}
	return nil
}

func validateStreamTiming(source, joined []ffprobe.Packet, partOffset float64) (float64, float64, error) {
	offset := joined[0].PTS - source[0].PTS
	startTolerance := timingTolerance
	if !math.IsNaN(source[0].Duration) {
		startTolerance = math.Max(startTolerance, source[0].Duration)
	}

	// AVI positions audio and video on different packet grids. Permit
	// one source packet of start rounding, not accumulating drift.
	if math.Abs(offset-partOffset) > startTolerance+1e-9 {
		return 0, 0, fmt.Errorf("audio/video alignment changed")
	}

	first, last := math.Inf(1), math.Inf(-1)
	for index, packet := range source {
		actual := joined[index]
		if math.IsNaN(packet.PTS) || math.IsNaN(actual.PTS) ||
			!sameTime(packet.PTS+offset, actual.PTS) || !sameTime(packet.DTS+offset, actual.DTS) {
			return 0, 0, fmt.Errorf("packet %d: timestamp changed (source %.6f, output %.6f, offset %.6f)",
				index, packet.PTS, actual.PTS, offset)
		}

		// Container duration rounding may affect a part's last packet.
		if index+1 < len(source) && !sameTime(packet.Duration, actual.Duration) {
			return 0, 0, fmt.Errorf("packet %d: packet duration changed (source %.6f, output %.6f)",
				index, packet.Duration, actual.Duration)
		}

		first = math.Min(first, actual.PTS)
		end := actual.PTS
		if !math.IsNaN(actual.Duration) {
			end += actual.Duration
		}
		last = math.Max(last, end)
	}
	return first, last, nil
}

func sameTime(expected, actual float64) bool {
	// Some containers omit DTS or duration. Presentation timestamps remain
	// mandatory above; absent optional values cannot establish a mismatch.
	return math.IsNaN(expected) || math.IsNaN(actual) || math.Abs(expected-actual) <= timingTolerance+1e-9
}

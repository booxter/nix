package joinverification

import (
	"math"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/ffprobe"
)

func TestTimelineRejectsMissingPacketsAndChangedTiming(t *testing.T) {
	source := ffprobe.Timeline{0: {
		{PTS: 0, DTS: 0, Duration: .04},
		{PTS: .04, DTS: .04, Duration: .04},
	}}

	for name, output := range map[string]ffprobe.Timeline{
		"missing stream": {},
		"missing packet": {0: {source[0][0]}},
		"extra packet":   {0: {source[0][0], source[0][1], source[0][1]}},
		"missing timestamp": {0: {
			source[0][0], {PTS: math.NaN(), DTS: math.NaN(), Duration: .04},
		}},
		"stretched presentation": {0: {
			source[0][0], {PTS: .08, DTS: .04, Duration: .04},
		}},
		"stretched decode": {0: {
			source[0][0], {PTS: .04, DTS: .08, Duration: .04},
		}},
		"changed duration": {0: {
			{PTS: 0, DTS: 0, Duration: .08}, source[0][1],
		}},
	} {
		t.Run(name, func(t *testing.T) {
			if err := ValidateTimeline([]ffprobe.Timeline{source}, output); err == nil {
				t.Fatal("accepted damaged packet timing")
			}
		})
	}
}

func TestTimelineRejectsCompressedMiddleDespiteMatchingLength(t *testing.T) {
	part := ffprobe.Timeline{0: {
		{PTS: 0, DTS: 0, Duration: .04},
		{PTS: .04, DTS: .04, Duration: .04},
		{PTS: .08, DTS: .08, Duration: .04},
	}}
	output := ffprobe.Timeline{0: {
		{PTS: 0, DTS: 0, Duration: .04},
		{PTS: .04, DTS: .04, Duration: .04},
		{PTS: .08, DTS: .08, Duration: .04},
		{PTS: .12, DTS: .12, Duration: .000078},
		{PTS: .120078, DTS: .120078, Duration: .000078},
		{PTS: .120156, DTS: .120156, Duration: .119844},
		{PTS: .24, DTS: .24, Duration: .04},
		{PTS: .28, DTS: .28, Duration: .04},
		{PTS: .32, DTS: .32, Duration: .04},
	}}
	if err := ValidateTimeline([]ffprobe.Timeline{part, part, part}, output); err == nil {
		t.Fatal("accepted a compressed scene hidden inside otherwise correct timing")
	}
}

func TestTimelineAcceptsVariableFrameRateAndPresentationReordering(t *testing.T) {
	part := ffprobe.Timeline{0: {
		{PTS: .04, DTS: 0, Duration: .04},
		{PTS: .12, DTS: .04, Duration: .04},
		{PTS: .08, DTS: .08, Duration: .08},
	}}
	output := ffprobe.Timeline{0: {
		{PTS: .04, DTS: 0, Duration: .04},
		{PTS: .12, DTS: .04, Duration: .04},
		{PTS: .08, DTS: .08, Duration: .08},
		{PTS: .16, DTS: .12, Duration: .04},
		{PTS: .24, DTS: .16, Duration: .04},
		{PTS: .20, DTS: .20, Duration: .08},
	}}
	if err := ValidateTimeline([]ffprobe.Timeline{part, part}, output); err != nil {
		t.Fatal(err)
	}
}

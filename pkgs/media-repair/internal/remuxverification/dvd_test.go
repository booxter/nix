package remuxverification

import (
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
)

func TestValidateDVDOutputAllowsCanaryTimestampTail(t *testing.T) {
	t.Parallel()
	const titleDuration = int64(9_779_000)
	tracks := []dvdvideo.Track{{Kind: "video", Codec: "mpeg2video"}, {Kind: "audio", Codec: "ac3"}}
	evidence := controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names: []string{"matroska", "webm"}, DurationMS: pointer(int64(9_788_385)),
		},
		Streams: []controller.ProbeStream{
			{Kind: pointer(controller.ProbeStreamVideo), CodecName: pointer("mpeg2video")},
			{Kind: pointer(controller.ProbeStreamAudio), CodecName: pointer("ac3")},
		},
		Chapters: make([]controller.ProbeChapter, 12),
	}
	evidence.Chapters[11].EndTimeMS = pointer(titleDuration)
	if err := ValidateDVDOutput(titleDuration, 12, tracks, evidence); err != nil {
		t.Fatalf("valid DVD output rejected: %v", err)
	}
	evidence.Format.DurationMS = pointer(titleDuration + 16_000)
	if err := ValidateDVDOutput(titleDuration, 12, tracks, evidence); err == nil {
		t.Fatal("DVD output with excessive duration drift was accepted")
	}
	evidence.Format.DurationMS = pointer(titleDuration)
	evidence.Streams[1].CodecName = pointer("aac")
	if err := ValidateDVDOutput(titleDuration, 12, tracks, evidence); err == nil {
		t.Fatal("DVD output with a changed audio codec was accepted")
	}
}

func pointer[T any](value T) *T { return &value }

package remuxverification

import (
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/mkvmerge"
)

func TestValidateOutputRequiresTheSelectedPlaylist(t *testing.T) {
	t.Parallel()
	duration := int64(5_629_500)
	video := controller.ProbeStreamVideo
	audio := controller.ProbeStreamAudio
	evidence := controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names: []string{"matroska", "webm"}, DurationMS: &duration,
		},
		Streams: []controller.ProbeStream{{Kind: &video}, {Kind: &audio}},
		Chapters: []controller.ProbeChapter{
			{ID: 1}, {ID: 2}, {ID: 3}, {ID: 4}, {ID: 5},
		},
	}
	tracks := []mkvmerge.Track{
		{Kind: "video", Codec: "AVC"}, {Kind: "audio", Codec: "AC-3"},
	}
	if err := ValidateOutput(5_629_498, 5, tracks, evidence); err != nil {
		t.Fatalf("valid remux output: %v", err)
	}
	wrongDuration := int64(5_620_000)
	evidence.Format.DurationMS = &wrongDuration
	if err := ValidateOutput(5_629_498, 5, tracks, evidence); err == nil {
		t.Fatal("accepted output with wrong duration")
	}
	evidence.Format.DurationMS = &duration
	evidence.Chapters = evidence.Chapters[:4]
	if err := ValidateOutput(5_629_498, 5, tracks, evidence); err == nil {
		t.Fatal("accepted output missing a chapter")
	}
	evidence.Chapters = append(evidence.Chapters, controller.ProbeChapter{ID: 5})
	evidence.Streams = evidence.Streams[:1]
	if err := ValidateOutput(5_629_498, 5, tracks, evidence); err == nil {
		t.Fatal("accepted output missing an audio stream")
	}
}

package remuxverification

import (
	"fmt"
	"reflect"
	"slices"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/mkvmerge"
)

const durationToleranceMS = 5_000

func ValidateOutput(
	expectedDurationMS int64,
	expectedChapterCount int,
	expectedTracks []mkvmerge.Track,
	evidence controller.ProbeEvidence,
) error {
	if !slices.Contains(evidence.Format.Names, "matroska") ||
		evidence.Format.DurationMS == nil ||
		len(evidence.Chapters) != expectedChapterCount {
		return fmt.Errorf("Blu-ray remux output format or chapters differ from playlist")
	}
	difference := *evidence.Format.DurationMS - expectedDurationMS
	if difference < 0 {
		difference = -difference
	}
	if difference > durationToleranceMS {
		return fmt.Errorf("Blu-ray remux output duration differs from playlist")
	}
	want := map[controller.ProbeStreamKind]int{}
	for _, track := range expectedTracks {
		kind := controller.ProbeStreamKind(track.Kind)
		if kind == "subtitles" {
			kind = controller.ProbeStreamSubtitle
		}
		want[kind]++
	}
	got := map[controller.ProbeStreamKind]int{}
	for _, stream := range evidence.Streams {
		if stream.Kind == nil {
			return fmt.Errorf("Blu-ray remux output stream kind is unknown")
		}
		got[*stream.Kind]++
	}
	if !reflect.DeepEqual(got, want) || got[controller.ProbeStreamVideo] == 0 {
		return fmt.Errorf("Blu-ray remux output streams differ from playlist")
	}
	return nil
}

package remuxverification

import (
	"fmt"
	"slices"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
)

const dvdDurationToleranceMS = 15_000

func ValidateDVDOutput(
	expectedDurationMS int64,
	expectedChapterCount int,
	expectedTracks []dvdvideo.Track,
	evidence controller.ProbeEvidence,
) error {
	if !slices.Contains(evidence.Format.Names, "matroska") ||
		evidence.Format.DurationMS == nil ||
		len(evidence.Chapters) != expectedChapterCount ||
		expectedChapterCount <= 0 {
		return fmt.Errorf("DVD remux output format or chapters differ from title")
	}
	difference := *evidence.Format.DurationMS - expectedDurationMS
	if difference < 0 {
		difference = -difference
	}
	if difference > dvdDurationToleranceMS {
		return fmt.Errorf("DVD remux output duration differs from title")
	}
	lastChapter := evidence.Chapters[len(evidence.Chapters)-1]
	if lastChapter.EndTimeMS == nil || *lastChapter.EndTimeMS < expectedDurationMS-dvdDurationToleranceMS ||
		*lastChapter.EndTimeMS > expectedDurationMS+dvdDurationToleranceMS {
		return fmt.Errorf("DVD remux output chapter endpoint differs from title")
	}
	want := make(map[string]int)
	for _, track := range expectedTracks {
		want[track.Kind+":"+track.Codec]++
	}
	got := make(map[string]int)
	for _, stream := range evidence.Streams {
		if stream.Kind == nil || stream.CodecName == nil {
			return fmt.Errorf("DVD remux output stream is unidentified")
		}
		kind := string(*stream.Kind)
		if kind == "subtitle" {
			kind = "subtitles"
		}
		got[kind+":"+*stream.CodecName]++
	}
	if len(got) != len(want) {
		return fmt.Errorf("DVD remux output tracks differ from title")
	}
	for track, count := range want {
		if got[track] != count {
			return fmt.Errorf("DVD remux output tracks differ from title")
		}
	}
	if want["video:mpeg2video"] == 0 || len(evidence.Streams) != len(expectedTracks) {
		return fmt.Errorf("DVD remux output has no matching movie video")
	}
	return nil
}

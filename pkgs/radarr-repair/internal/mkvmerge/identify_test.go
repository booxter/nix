package mkvmerge

import (
	"os"
	"path/filepath"
	"testing"
)

func TestIdentifiesCurrentQueuePlaylist(t *testing.T) {
	t.Parallel()
	data, err := os.ReadFile(filepath.Join("testdata", "pandora-identification.json"))
	if err != nil {
		t.Fatal(err)
	}

	playlist, err := decodePlaylist(data)
	if err != nil {
		t.Fatal(err)
	}
	if playlist.DurationMS < 93*60*1000 || playlist.DurationMS > 95*60*1000 {
		t.Errorf("feature duration = %d ms", playlist.DurationMS)
	}
	if playlist.Chapters != 5 {
		t.Errorf("chapter count = %d, want 5", playlist.Chapters)
	}
	if len(playlist.ClipPaths) != 1 ||
		playlist.ClipPaths[0] != "/disc/BDMV/STREAM/00000.m2ts" {
		t.Errorf("feature clips = %v", playlist.ClipPaths)
	}
	if len(playlist.Tracks) != 5 || playlist.Tracks[0].Kind != "video" ||
		playlist.Tracks[4].Kind != "subtitles" {
		t.Errorf("feature tracks = %v", playlist.Tracks)
	}
}

func TestRejectsUnidentifiedPlaylist(t *testing.T) {
	t.Parallel()
	_, err := decodePlaylist([]byte(`{"container":{"recognized":false}}`))
	if err == nil {
		t.Fatal("accepted an unidentified playlist")
	}
}

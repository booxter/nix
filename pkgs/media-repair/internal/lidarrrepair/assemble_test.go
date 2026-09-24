package lidarrrepair

import (
	"fmt"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

func TestAssembleNormalizesExternalLists(t *testing.T) {
	t.Parallel()
	albumID, artistID := int64(3), int64(2)
	messages := make([]string, 300)
	countries := make([]string, 80)
	for index := range messages {
		messages[index] = fmt.Sprintf("message %03d", index)
	}
	for index := range countries {
		countries[index] = fmt.Sprintf("country %03d", index)
	}
	queue := lidarr.QueueRecord{
		ID: 1, AlbumID: &albumID, ArtistID: &artistID, Title: "Artist - Album",
		DownloadID: "download", StatusMessages: []lidarr.StatusMessage{{Messages: messages}},
	}
	album := lidarr.Album{
		ID: albumID, ArtistID: artistID, ArtistName: "Artist", Title: "Album",
		Releases: []lidarr.Release{{
			ID: 4, ForeignReleaseID: "release", Title: "Album", Format: "Album",
			Countries: countries, Labels: []string{" Label ", "Label"},
			TrackCount: 1, MediumCount: 1, Monitored: true,
		}},
	}
	tracks := []lidarr.Track{{
		ID: 5, AlbumID: albumID, ReleaseID: 4, ArtistID: artistID,
		AbsoluteTrackNumber: 1, TrackNumber: "1", MediumNumber: 1, Title: "Track",
	}}
	materialized := testMaterialization(
		materialize.OperationMaterializeDirectory,
		"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
	)
	imports := []lidarr.ManualImport{{
		Path: "/downloads/.media-repair/workspaces/workspace:test/01.flac",
		Name: "01.flac", SizeBytes: 100, ArtistID: artistID, AlbumID: albumID,
		AlbumReleaseID: 4,
		AudioTags:      &lidarr.AudioTags{TrackNumbers: []int{0, 1, 1}},
	}}
	repairCase, _, err := Assemble(
		time.Unix(1, 0), queue, album, tracks, materialized, imports, &fakeWorker{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(repairCase.Queue.Messages) != maximumQueueMessages ||
		repairCase.Artifacts[0].ArtifactID != "artifact:1" ||
		repairCase.Assessments[0].ArtifactID != "artifact:1" ||
		repairCase.Capabilities[0].ArtifactIDs[0] != "artifact:1" ||
		len(repairCase.Releases[0].Countries) != maximumReleaseNames ||
		len(repairCase.Releases[0].Labels) != 1 ||
		repairCase.Assessments[0].TrackIDs == nil ||
		len(repairCase.Assessments[0].TrackIDs) != 0 ||
		len(repairCase.Assessments[0].TagTrackNumbers) != 1 ||
		repairCase.Assessments[0].TagTrackNumbers[0] != 1 {
		t.Fatalf("case was not normalized: %#v", repairCase)
	}
}

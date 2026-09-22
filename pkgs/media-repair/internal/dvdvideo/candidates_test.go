package dvdvideo

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

type fixtureIdentifier struct{ titles []Title }

func (fixture fixtureIdentifier) IdentifyDVD(_ context.Context, _ Target) ([]Title, error) {
	return fixture.titles, nil
}

func TestFeatureTitlesRequireCompleteDVDTree(t *testing.T) {
	t.Parallel()
	inventory := dvdInventory(
		"Movie/VIDEO_TS/VIDEO_TS.IFO",
		"Movie/VIDEO_TS/VIDEO_TS.BUP",
		"Movie/VIDEO_TS/VTS_01_0.IFO",
		"Movie/VIDEO_TS/VTS_01_1.VOB",
	)
	identifier := fixtureIdentifier{titles: []Title{
		{Number: 1, DurationMS: 9_779_000, Chapters: 12, Angles: 1,
			TitleSet: 1, TitleInSet: 1,
			Tracks: []Track{{Kind: "video", Codec: "mpeg2video"}, {Kind: "audio", Codec: "ac3"}}},
		{Number: 2, DurationMS: 60_000, Chapters: 2, Angles: 1,
			TitleSet: 1, TitleInSet: 2,
			Tracks: []Track{{Kind: "video", Codec: "mpeg2video"}, {Kind: "audio", Codec: "ac3"}}},
	}}
	candidates, err := ListFeatureTitles(context.Background(), inventory, identifier)
	if err != nil {
		t.Fatal(err)
	}
	if len(candidates) != 1 || candidates[0].Details.Number != 1 ||
		len(candidates[0].SourceFileIDs) != 4 ||
		candidates[0].NavigationFileID != controller.FileID("Movie/VIDEO_TS/VIDEO_TS.IFO") {
		t.Fatalf("DVD feature candidates = %#v", candidates)
	}

	inventory.Files[3].DownloadFile.BytesCompleted--
	candidates, err = ListFeatureTitles(context.Background(), inventory, identifier)
	if err != nil || len(candidates) != 0 {
		t.Fatalf("incomplete DVD candidates = %#v, %v", candidates, err)
	}
}

func dvdInventory(paths ...string) controller.FileInventory {
	inventory := controller.FileInventory{}
	for _, path := range paths {
		id := controller.FileID(path)
		inventory.Files = append(inventory.Files, controller.InventoryFile{
			ID: id, PathComponents: strings.Split(path, "/"),
			Fingerprint: controller.FileFingerprint{SizeBytes: 100},
			DownloadFile: &controller.DownloadFileReference{
				LengthBytes: 100, BytesCompleted: 100, Selected: true,
			},
		})
		inventory.Paths = append(inventory.Paths, controller.FilePathMapping{
			FileID: id, AbsolutePath: filepath.Join("/download", path),
		})
	}
	return inventory
}

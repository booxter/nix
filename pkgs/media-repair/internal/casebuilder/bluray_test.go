package casebuilder

import (
	"testing"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
)

func TestBluRayCapabilitiesKeepDistinctChapterPlaylists(t *testing.T) {
	t.Parallel()
	const (
		plainID    = controller.FileID("file:plain")
		chaptersID = controller.FileID("file:chapters")
		clipID     = controller.FileID("file:clip")
	)
	files := map[controller.FileID]controller.InventoryFile{
		plainID:    {ID: plainID, Fingerprint: controller.FileFingerprint{SizeBytes: 190}},
		chaptersID: {ID: chaptersID, Fingerprint: controller.FileFingerprint{SizeBytes: 372}},
		clipID:     {ID: clipID, Fingerprint: controller.FileFingerprint{SizeBytes: 1_000}},
	}
	main := mkvmerge.Playlist{
		DurationMS: 100 * 60 * 1000,
		ClipPaths:  []string{"/disc/BDMV/STREAM/00004.m2ts"},
		Tracks: []mkvmerge.Track{
			{Kind: "video", Codec: "AVC/H.264/MPEG-4p10"},
			{Kind: "audio", Codec: "DTS-HD Master Audio", Language: "eng"},
		},
	}
	plain := main
	plain.Chapters = 1
	chaptered := main
	chaptered.Chapters = 10
	candidates := []mkvmerge.Candidate{
		{PlaylistFileID: plainID, ClipFileIDs: []controller.FileID{clipID}, Details: plain},
		{PlaylistFileID: chaptersID, ClipFileIDs: []controller.FileID{clipID}, Details: chaptered},
	}

	capabilities, err := bindBluRayCapabilities(candidates, files)
	if err != nil {
		t.Fatal(err)
	}
	if len(capabilities) != 2 || capabilities[0].CapabilityID == capabilities[1].CapabilityID {
		t.Fatalf("playlist capabilities = %v", capabilities)
	}
	for index, capability := range capabilities {
		if capability.Action != contracts.CapabilityActionRemuxBluray ||
			capability.PlaylistFileID == nil ||
			*capability.PlaylistFileID != string(candidates[index].PlaylistFileID) ||
			len(capability.ClipFileIDS) != 1 || capability.ClipFileIDS[0] != string(clipID) ||
			len(capability.Tracks) != 2 {
			t.Fatalf("playlist capability %d = %v", index, capability)
		}
	}
	if *capabilities[0].ChapterCount != 1 || *capabilities[1].ChapterCount != 10 {
		t.Errorf("chapter alternatives = %v", capabilities)
	}
}

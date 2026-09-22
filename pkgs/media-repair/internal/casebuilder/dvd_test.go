package casebuilder

import (
	"testing"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
)

func TestDVDCapabilityBindsTitleAndWholeDiscSnapshot(t *testing.T) {
	t.Parallel()
	navigationID := controller.FileID("file:navigation")
	vobID := controller.FileID("file:vob")
	files := map[controller.FileID]controller.InventoryFile{
		navigationID: {ID: navigationID, Fingerprint: controller.FileFingerprint{SizeBytes: 12_288}},
		vobID:        {ID: vobID, Fingerprint: controller.FileFingerprint{SizeBytes: 1_073_709_056}},
	}
	title := dvdvideo.Candidate{
		NavigationFileID: navigationID,
		SourceFileIDs:    []controller.FileID{navigationID, vobID},
		Details: dvdvideo.Title{
			Number: 1, DurationMS: 9_779_000, Chapters: 12, Angles: 1,
			TitleSet: 1, TitleInSet: 1,
			Tracks: []dvdvideo.Track{{Kind: "video", Codec: "mpeg2video"}, {Kind: "audio", Codec: "ac3"}},
		},
	}
	capabilities, err := bindDVDCapabilities([]dvdvideo.Candidate{title}, files)
	if err != nil {
		t.Fatal(err)
	}
	if len(capabilities) != 1 || capabilities[0].Action != contracts.CapabilityActionRemuxDVD ||
		capabilities[0].TitleNumber == nil || *capabilities[0].TitleNumber != 1 ||
		capabilities[0].NavigationFileID == nil || *capabilities[0].NavigationFileID != string(navigationID) ||
		len(capabilities[0].SourceFileIDS) != 2 {
		t.Fatalf("DVD capabilities = %#v", capabilities)
	}
	previousID := capabilities[0].CapabilityID
	file := files[vobID]
	file.Fingerprint.MTimeNS++
	files[vobID] = file
	changed, err := bindDVDCapabilities([]dvdvideo.Candidate{title}, files)
	if err != nil || changed[0].CapabilityID == previousID {
		t.Fatalf("changed DVD source retained capability identity: %#v, %v", changed, err)
	}
}

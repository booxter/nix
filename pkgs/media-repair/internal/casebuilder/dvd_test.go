package casebuilder

import (
	"slices"
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
	file.Fingerprint.Device++
	files[vobID] = file
	remounted, err := bindDVDCapabilities([]dvdvideo.Candidate{title}, files)
	if err != nil || remounted[0].CapabilityID != previousID {
		t.Fatalf("remounted DVD source changed capability identity: %#v, %v", remounted, err)
	}
	file = files[vobID]
	file.Fingerprint.MTimeNS++
	files[vobID] = file
	changed, err := bindDVDCapabilities([]dvdvideo.Candidate{title}, files)
	if err != nil || changed[0].CapabilityID == previousID {
		t.Fatalf("changed DVD source retained capability identity: %#v, %v", changed, err)
	}
}

func TestDVDPlaybackLinksUseTheOfferedEquivalentTitle(t *testing.T) {
	t.Parallel()
	navigation := controller.FileID("file:disc")
	files := map[controller.FileID]controller.InventoryFile{navigation: {ID: navigation}}
	var titles []dvdvideo.Candidate
	for number := 1; number <= 3; number++ {
		titles = append(titles, dvdvideo.Candidate{
			NavigationFileID: navigation,
			SourceFileIDs:    []controller.FileID{navigation},
			Details: dvdvideo.Title{
				Number: number, TitleInSet: number, TitleSet: 1,
				DurationMS: 1_117_200, Chapters: 1, Angles: 1,
				Tracks: []dvdvideo.Track{{Kind: "video", Codec: "mpeg2video"}, {Kind: "audio", Codec: "ac3"}},
			},
		})
	}
	titles[0].Details.NextTitle = 3
	titles[2].Details.EquivalentTo = 2
	overlap := dvdvideo.Overlap{Title: 3, SharedDurationMS: 1_100_000,
		Ranges: []dvdvideo.OverlapRange{{StartMS: 17_200, OtherStartMS: 0, DurationMS: 1_100_000}},
	}
	titles[0].Details.Overlaps = []dvdvideo.Overlap{overlap}
	overlap.Title = 2
	titles[0].Details.Overlaps = append(titles[0].Details.Overlaps, overlap)
	overlap.Title = 99
	titles[0].Details.Overlaps = append(titles[0].Details.Overlaps, overlap)
	overlap.Title = 3
	titles[1].Details.Overlaps = []dvdvideo.Overlap{overlap}

	capabilities, err := bindDVDCapabilities(titles, files)
	if err != nil {
		t.Fatal(err)
	}
	if len(capabilities) != 2 || capabilities[0].ContinuesTo == nil ||
		*capabilities[0].ContinuesTo != capabilities[1].CapabilityID ||
		!slices.Equal(capabilities[1].EquivalentTitleNumbers, []int64{3}) {
		t.Fatalf("offered DVD playback = %#v", capabilities)
	}
	if len(capabilities[0].Overlaps) != 1 || len(capabilities[1].Overlaps) != 0 {
		t.Fatalf("overlaps include duplicate, missing, or equivalent titles: %+v", capabilities)
	}
	relation := capabilities[0].Overlaps[0]
	if relation.CapabilityID != capabilities[1].CapabilityID || relation.SharedDurationMS != 1_100_000 ||
		len(relation.Ranges) != 1 || relation.Ranges[0].StartMS != 17_200 ||
		relation.Ranges[0].OtherStartMS != 0 || relation.Ranges[0].DurationMS != 1_100_000 {
		t.Fatalf("overlap changed when binding offered titles: %+v", relation)
	}
}

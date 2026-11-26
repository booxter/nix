package decisionpolicy

import (
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
)

func TestValidateDVDRequiresCompleteMatchingTitle(t *testing.T) {
	t.Parallel()
	assembly, decision := dvdCase()
	authorized, reason := ValidateDVD(assembly, decision, RuntimePolicy{})
	if reason != "" || authorized == nil ||
		len(authorized.Titles) != 1 || authorized.Titles[0].TitleNumber != 1 ||
		len(authorized.Titles[0].Sources) != 2 {
		t.Fatalf("DVD authorization = %#v, reason = %q", authorized, reason)
	}
	assembly.LocalSnapshot.Observation.Inventory.Files[1].DownloadFile.BytesCompleted--
	if authorized, reason := ValidateDVD(assembly, decision, RuntimePolicy{}); authorized != nil || reason != RemuxFileUnavailable {
		t.Fatalf("incomplete DVD source: %#v, %q", authorized, reason)
	}
}

func TestValidateDVDAcceptsFlatDirectory(t *testing.T) {
	t.Parallel()
	assembly, decision := dvdCase()
	for index := range assembly.LocalSnapshot.Observation.Inventory.Paths {
		path := &assembly.LocalSnapshot.Observation.Inventory.Paths[index]
		path.AbsolutePath = filepath.Join("/media/movie", filepath.Base(path.AbsolutePath))
	}
	if authorized, reason := ValidateDVD(assembly, decision, RuntimePolicy{}); authorized == nil || reason != "" {
		t.Fatalf("flat DVD authorization = %#v, reason = %q", authorized, reason)
	}
}

func TestValidateDVDRejectsChangedTitleAndRuntime(t *testing.T) {
	t.Parallel()
	assembly, decision := dvdCase()
	assembly.LocalSnapshot.Observation.DVDTitles[0].Details.Chapters++
	if authorized, reason := ValidateDVD(assembly, decision, RuntimePolicy{}); authorized != nil || reason != RemuxPlaylistMismatch {
		t.Fatalf("changed DVD title: %#v, %q", authorized, reason)
	}
	assembly, decision = dvdCase()
	runtime := 90
	assembly.LocalSnapshot.Observation.Movie.RuntimeMinutes = &runtime
	if authorized, reason := ValidateDVD(assembly, decision, RuntimePolicy{}); authorized != nil || reason != RemuxRuntimeMismatch {
		t.Fatalf("wrong movie runtime: %#v, %q", authorized, reason)
	}
}

func TestValidateDVDAcceptsAuthorizedRuntimeDifference(t *testing.T) {
	t.Parallel()
	assembly, decision := dvdCase()
	runtime := 148
	const titleDurationMS = int64(126.5 * 60 * 1_000)
	assembly.LocalSnapshot.Observation.Movie.RuntimeMinutes = &runtime
	assembly.LocalSnapshot.Observation.DVDTitles[0].Details.DurationMS = titleDurationMS
	assembly.Request.Capabilities[0].DurationMS = pointer(titleDurationMS)

	if authorized, reason := ValidateDVD(assembly, decision, RuntimePolicy{}); authorized != nil || reason != RemuxRuntimeMismatch {
		t.Fatalf("default policy: %#v, %q", authorized, reason)
	}
	authorized, reason := ValidateDVD(assembly, decision, RuntimePolicy{
		MaximumDifferenceMS: 30 * 60 * 1_000,
	})
	if reason != "" || authorized == nil || authorized.RuntimeToleranceMS != 30*60*1_000 {
		t.Fatalf("override authorization = %#v, reason = %q", authorized, reason)
	}
}

func TestValidateDVDUsesCombinedRuntimeAndKeepsSelectedTitleOrder(t *testing.T) {
	t.Parallel()
	assembly, decision := dvdCase()
	first := &assembly.LocalSnapshot.Observation.DVDTitles[0]
	first.Details.DurationMS = 4_000_000
	assembly.Request.Capabilities[0].DurationMS = pointer(first.Details.DurationMS)
	second := *first
	second.Details.Number = 2
	second.Details.DurationMS = 5_779_000
	assembly.LocalSnapshot.Observation.DVDTitles = append(assembly.LocalSnapshot.Observation.DVDTitles, second)
	capability := assembly.Request.Capabilities[0]
	capability.CapabilityID = "capability:dvd-second"
	capability.TitleNumber = pointer(int64(2))
	capability.DurationMS = pointer(second.Details.DurationMS)
	assembly.Request.Capabilities = append(assembly.Request.Capabilities, capability)

	if authorized, reason := ValidateDVD(assembly, decision, RuntimePolicy{}); authorized != nil || reason != RemuxRuntimeMismatch {
		t.Fatalf("incomplete selection: %#v, %q", authorized, reason)
	}
	decision.RemuxDVD.OrderedTitleIDS = []string{capability.CapabilityID, "capability:dvd"}
	authorized, reason := ValidateDVD(assembly, decision, RuntimePolicy{})
	if reason != "" || authorized == nil || len(authorized.Titles) != 2 ||
		authorized.Titles[0].TitleNumber != 2 || authorized.Titles[1].TitleNumber != 1 {
		t.Fatalf("combined DVD authorization: %#v, %q", authorized, reason)
	}

	decision.RemuxDVD.OrderedTitleIDS = []string{capability.CapabilityID, capability.CapabilityID}
	if authorized, _ := ValidateDVD(assembly, decision, RuntimePolicy{}); authorized != nil {
		t.Fatal("accepted the same DVD title twice")
	}
}

func dvdCase() (casebuilder.Assembly, contracts.RepairDecisionV3) {
	const caseID, capabilityID = "case:dvd", "capability:dvd"
	navigationPath := filepath.Join("/media/movie", "VIDEO_TS", "VIDEO_TS.IFO")
	vobPath := filepath.Join("/media/movie", "VIDEO_TS", "VTS_01_1.VOB")
	runtime := 163
	request := contracts.RepairCaseV3{
		CaseID: caseID,
		Capabilities: []contracts.Capability{{
			Action: contracts.CapabilityActionRemuxDVD, CapabilityID: capabilityID,
			NavigationFileID: pointer("navigation"), SourceFileIDS: []string{"navigation", "vob"},
			TitleNumber: pointer(int64(1)), TitleSet: pointer(int64(1)),
			TitleInSet: pointer(int64(1)), AngleCount: pointer(int64(1)),
			DurationMS: pointer(int64(9_779_000)), ChapterCount: pointer(int64(12)),
			Tracks: []contracts.TrackElement{
				{Kind: "video", Codec: "mpeg2video"}, {Kind: "audio", Codec: "ac3"},
			},
		}},
	}
	observation := casebuilder.Observation{
		Movie: &controller.RadarrMovie{ID: 1, RuntimeMinutes: &runtime},
		Inventory: controller.FileInventory{
			Files: []controller.InventoryFile{
				{ID: "navigation", Fingerprint: controller.FileFingerprint{SizeBytes: 12_288}},
				{ID: "vob", Fingerprint: controller.FileFingerprint{SizeBytes: 1_000_000},
					DownloadFile: &controller.DownloadFileReference{
						Selected: true, LengthBytes: 1_000_000, BytesCompleted: 1_000_000,
					}},
			},
			Paths: []controller.FilePathMapping{
				{FileID: "navigation", AbsolutePath: navigationPath},
				{FileID: "vob", AbsolutePath: vobPath},
			},
		},
		DVDTitles: []dvdvideo.Candidate{{
			NavigationFileID: "navigation", SourceFileIDs: []controller.FileID{"navigation", "vob"},
			Details: dvdvideo.Title{Number: 1, DurationMS: 9_779_000, Chapters: 12,
				Angles: 1, TitleSet: 1, TitleInSet: 1,
				Tracks: []dvdvideo.Track{{Kind: "video", Codec: "mpeg2video"}, {Kind: "audio", Codec: "ac3"}}},
		}},
	}
	assembly := casebuilder.Assembly{
		Request:       request,
		LocalSnapshot: casebuilder.LocalSnapshot{CaseID: caseID, Observation: observation},
	}
	decision := contracts.RepairDecisionV3{
		Kind: contracts.ActionRemuxDVD,
		RemuxDVD: &contracts.RemuxDVDDecision{
			Action: "remux_dvd_v2", CaseID: caseID, OrderedTitleIDS: []string{capabilityID},
		},
	}
	return assembly, decision
}

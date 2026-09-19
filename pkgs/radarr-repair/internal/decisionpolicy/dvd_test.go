package decisionpolicy

import (
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/dvdvideo"
)

func TestValidateDVDRequiresCompleteMatchingTitle(t *testing.T) {
	t.Parallel()
	assembly, decision := dvdCase()
	validation := ValidateDVD(assembly, decision)
	if !validation.Accepted() || validation.Authorized == nil ||
		validation.Authorized.TitleNumber != 1 || len(validation.Authorized.Sources) != 2 {
		t.Fatalf("DVD authorization = %#v", validation)
	}
	assembly.LocalSnapshot.Observation.Inventory.Files[1].DownloadFile.BytesCompleted--
	if rejection := ValidateDVD(assembly, decision); rejection.Accepted() ||
		len(rejection.Rejections) != 1 || rejection.Rejections[0] != RemuxFileUnavailable {
		t.Fatalf("incomplete DVD source was authorized: %#v", rejection)
	}
}

func TestValidateDVDRejectsChangedTitleAndRuntime(t *testing.T) {
	t.Parallel()
	assembly, decision := dvdCase()
	assembly.LocalSnapshot.Observation.DVDTitles[0].Details.Chapters++
	if rejection := ValidateDVD(assembly, decision); rejection.Accepted() ||
		rejection.Rejections[0] != RemuxPlaylistMismatch {
		t.Fatalf("changed DVD title was authorized: %#v", rejection)
	}
	assembly, decision = dvdCase()
	runtime := 90
	assembly.LocalSnapshot.Observation.Movie.RuntimeMinutes = &runtime
	if rejection := ValidateDVD(assembly, decision); rejection.Accepted() ||
		rejection.Rejections[0] != RemuxRuntimeMismatch {
		t.Fatalf("wrong movie runtime was authorized: %#v", rejection)
	}
}

func dvdCase() (casebuilder.Assembly, contracts.RepairDecisionV2) {
	const caseID, capabilityID = "case:dvd", "capability:dvd"
	navigationPath := filepath.Join("/media/movie", "VIDEO_TS", "VIDEO_TS.IFO")
	vobPath := filepath.Join("/media/movie", "VIDEO_TS", "VTS_01_1.VOB")
	runtime := 163
	request := contracts.RepairCaseV2{
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
	decision := contracts.RepairDecisionV2{
		Kind: contracts.ActionRemuxDVD,
		RemuxDVD: &contracts.RemuxDVDDecision{
			Action: "remux_dvd_v1", CaseID: caseID, CapabilityID: capabilityID,
		},
	}
	return assembly, decision
}

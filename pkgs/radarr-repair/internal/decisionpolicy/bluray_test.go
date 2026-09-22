package decisionpolicy

import (
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/mkvmerge"
)

func TestValidateRemuxAuthorizesCompleteMatchingDisc(t *testing.T) {
	t.Parallel()
	assembly, decision := remuxCase()
	validation := ValidateRemux(assembly, decision)
	if !validation.Accepted() || validation.Authorized == nil {
		t.Fatalf("remux authorization = %#v", validation)
	}
	if validation.Authorized.Playlist.FileID != "playlist" ||
		len(validation.Authorized.Clips) != 1 ||
		validation.Authorized.Clips[0].FileID != "clip" ||
		validation.Authorized.SourceBytes != 1_000_000 ||
		validation.Authorized.ExpectedDurationMS != 5_629_498 ||
		validation.Authorized.ExpectedChapters != 5 {
		t.Fatalf("authorized remux = %#v", validation.Authorized)
	}
}

func TestValidateRemuxRejectsRuntimeMismatch(t *testing.T) {
	t.Parallel()
	assembly, decision := remuxCase()
	runtime := 116
	assembly.LocalSnapshot.Observation.Movie.RuntimeMinutes = &runtime
	assertRemuxRejection(t, ValidateRemux(assembly, decision), RemuxRuntimeMismatch)
}

func TestValidateRemuxRejectsIncompleteClip(t *testing.T) {
	t.Parallel()
	assembly, decision := remuxCase()
	assembly.LocalSnapshot.Observation.Inventory.Files[1].DownloadFile.BytesCompleted--
	assertRemuxRejection(t, ValidateRemux(assembly, decision), RemuxFileUnavailable)
}

func TestValidateRemuxRejectsChangedPlaylistEvidence(t *testing.T) {
	t.Parallel()
	assembly, decision := remuxCase()
	assembly.LocalSnapshot.Observation.BluRayPlaylists[0].Details.Tracks[0].Codec = "different"
	assertRemuxRejection(t, ValidateRemux(assembly, decision), RemuxPlaylistMismatch)
}

func TestValidateRemuxRejectsUnknownCapability(t *testing.T) {
	t.Parallel()
	assembly, decision := remuxCase()
	decision.RemuxBluray.CapabilityID = "other"
	assertRemuxRejection(t, ValidateRemux(assembly, decision), RemuxCapabilityMissing)
}

func assertRemuxRejection(
	t *testing.T,
	validation RemuxValidation,
	want RemuxRejectionReason,
) {
	t.Helper()
	if validation.Accepted() || len(validation.Rejections) != 1 ||
		validation.Rejections[0] != want {
		t.Fatalf("remux validation = %#v, want %q", validation, want)
	}
}

func remuxCase() (casebuilder.Assembly, contracts.RepairDecisionV3) {
	const (
		caseID       = "case:bluray"
		capabilityID = "capability:bluray"
	)
	playlistPath := filepath.Join("/media/movie", "BDMV", "PLAYLIST", "00000.mpls")
	clipPath := filepath.Join("/media/movie", "BDMV", "STREAM", "00000.m2ts")
	playlistFingerprint := controller.FileFingerprint{Device: 1, Inode: 2, SizeBytes: 100, MTimeNS: 3}
	clipFingerprint := controller.FileFingerprint{Device: 1, Inode: 4, SizeBytes: 1_000_000, MTimeNS: 3}
	runtime := 94
	request := contracts.RepairCaseV3{
		CaseID: caseID,
		Capabilities: []contracts.Capability{{
			Action:         contracts.CapabilityActionRemuxBluray,
			CapabilityID:   capabilityID,
			PlaylistFileID: pointer("playlist"),
			ClipFileIDS:    []string{"clip"},
			DurationMS:     pointer(int64(5_629_498)),
			ChapterCount:   pointer(int64(5)),
			Tracks: []contracts.TrackElement{{
				Kind: "video", Codec: "AVC/H.264/MPEG-4p10",
			}},
		}},
	}
	observation := casebuilder.Observation{
		Movie: &controller.RadarrMovie{ID: 1, RuntimeMinutes: &runtime},
		Inventory: controller.FileInventory{
			Files: []controller.InventoryFile{
				{
					ID: "playlist", Fingerprint: playlistFingerprint,
					DownloadFile: &controller.DownloadFileReference{
						Selected: true, LengthBytes: 100, BytesCompleted: 100,
					},
				},
				{
					ID: "clip", Fingerprint: clipFingerprint,
					DownloadFile: &controller.DownloadFileReference{
						Selected: true, LengthBytes: 1_000_000, BytesCompleted: 1_000_000,
					},
				},
			},
			Paths: []controller.FilePathMapping{
				{FileID: "playlist", AbsolutePath: playlistPath},
				{FileID: "clip", AbsolutePath: clipPath},
			},
		},
		BluRayPlaylists: []mkvmerge.Candidate{{
			PlaylistFileID: "playlist",
			ClipFileIDs:    []controller.FileID{"clip"},
			Details: mkvmerge.Playlist{
				DurationMS: 5_629_498,
				Chapters:   5,
				ClipPaths:  []string{clipPath},
				Tracks: []mkvmerge.Track{{
					Kind: "video", Codec: "AVC/H.264/MPEG-4p10",
				}},
			},
		}},
	}
	assembly := casebuilder.Assembly{
		Request: request,
		LocalSnapshot: casebuilder.LocalSnapshot{
			CaseID: caseID, Observation: observation,
		},
	}
	decision := contracts.RepairDecisionV3{
		Kind: contracts.ActionRemuxBluray,
		RemuxBluray: &contracts.RemuxBlurayDecision{
			Action: "remux_bluray_v1", CaseID: caseID, CapabilityID: capabilityID,
		},
	}
	return assembly, decision
}

func pointer[T any](value T) *T { return &value }

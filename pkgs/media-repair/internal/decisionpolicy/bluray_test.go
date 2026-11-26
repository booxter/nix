package decisionpolicy

import (
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
)

func TestValidateRemuxAuthorizesCompleteMatchingDisc(t *testing.T) {
	t.Parallel()
	assembly, decision := remuxCase()
	authorized, reason := ValidateRemux(assembly, decision, RuntimePolicy{})
	if reason != "" || authorized == nil {
		t.Fatalf("remux authorization = %#v, reason = %q", authorized, reason)
	}
	if authorized.Playlist.FileID != "playlist" ||
		len(authorized.Clips) != 1 ||
		authorized.Clips[0].FileID != "clip" ||
		authorized.SourceBytes != 1_000_000 ||
		authorized.ExpectedDurationMS != 5_629_498 ||
		authorized.ExpectedChapters != 5 {
		t.Fatalf("authorized remux = %#v", authorized)
	}
}

func TestValidateRemuxRejectsRuntimeMismatch(t *testing.T) {
	t.Parallel()
	assembly, decision := remuxCase()
	runtime := 116
	assembly.LocalSnapshot.Observation.Movie.RuntimeMinutes = &runtime
	authorized, reason := ValidateRemux(assembly, decision, RuntimePolicy{})
	assertRemuxRejection(t, authorized, reason, RemuxRuntimeMismatch)
}

func TestValidateRemuxRejectsIncompleteClip(t *testing.T) {
	t.Parallel()
	assembly, decision := remuxCase()
	assembly.LocalSnapshot.Observation.Inventory.Files[1].DownloadFile.BytesCompleted--
	authorized, reason := ValidateRemux(assembly, decision, RuntimePolicy{})
	assertRemuxRejection(t, authorized, reason, RemuxFileUnavailable)
}

func TestValidateRemuxRejectsChangedPlaylistEvidence(t *testing.T) {
	t.Parallel()
	assembly, decision := remuxCase()
	assembly.LocalSnapshot.Observation.BluRayPlaylists[0].Details.Tracks[0].Codec = "different"
	authorized, reason := ValidateRemux(assembly, decision, RuntimePolicy{})
	assertRemuxRejection(t, authorized, reason, RemuxPlaylistMismatch)
}

func TestValidateRemuxRejectsUnknownCapability(t *testing.T) {
	t.Parallel()
	assembly, decision := remuxCase()
	decision.RemuxBluray.CapabilityID = "other"
	authorized, reason := ValidateRemux(assembly, decision, RuntimePolicy{})
	assertRemuxRejection(t, authorized, reason, RemuxCapabilityMissing)
}

func assertRemuxRejection(
	t *testing.T,
	authorized *AuthorizedRemux,
	reason, want RemuxRejectionReason,
) {
	t.Helper()
	if authorized != nil || reason != want {
		t.Fatalf("remux authorization = %#v, reason = %q, want %q", authorized, reason, want)
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

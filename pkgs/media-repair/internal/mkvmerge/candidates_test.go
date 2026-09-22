package mkvmerge

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

type fixtureIdentifier map[string]Playlist

func (fixture fixtureIdentifier) Identify(_ context.Context, target Target) (Playlist, error) {
	playlist, exists := fixture[target.Path]
	if !exists {
		return Playlist{}, fmt.Errorf("unexpected playlist %q", target.Path)
	}
	return playlist, nil
}

func TestFeatureCandidatesPreservePlaylistAlternatives(t *testing.T) {
	t.Parallel()
	root := "/disc"
	inventory := testInventory(root,
		"BDMV/PLAYLIST/00004.mpls",
		"BDMV/PLAYLIST/01002.mpls",
		"BDMV/PLAYLIST/00005.mpls",
		"BDMV/BACKUP/PLAYLIST/00004.mpls",
		"BDMV/STREAM/00004.m2ts",
	)
	mainClip := filepath.Join(root, "BDMV/STREAM/00004.m2ts")
	identifier := fixtureIdentifier{
		filepath.Join(root, "BDMV/PLAYLIST/00004.mpls"): {
			DurationMS: 100 * 60 * 1000, Chapters: 1, ClipPaths: []string{mainClip},
		},
		filepath.Join(root, "BDMV/PLAYLIST/01002.mpls"): {
			DurationMS: 100 * 60 * 1000, Chapters: 10, ClipPaths: []string{mainClip},
		},
		filepath.Join(root, "BDMV/PLAYLIST/00005.mpls"): {
			DurationMS: 60 * 1000, Chapters: 1, ClipPaths: []string{mainClip},
		},
	}

	candidates, err := ListFeaturePlaylists(context.Background(), inventory, identifier)
	if err != nil {
		t.Fatal(err)
	}
	if len(candidates) != 2 {
		t.Fatalf("feature candidates = %d, want 2", len(candidates))
	}
	if candidates[0].Details.Chapters != 1 || candidates[1].Details.Chapters != 10 {
		t.Errorf("playlist alternatives = %v", candidates)
	}
	for _, candidate := range candidates {
		if len(candidate.ClipFileIDs) != 1 ||
			candidate.ClipFileIDs[0] != controller.FileID("BDMV/STREAM/00004.m2ts") {
			t.Errorf("candidate clips = %v", candidate.ClipFileIDs)
		}
	}
}

func TestRejectsClipOutsideDownload(t *testing.T) {
	t.Parallel()
	root := "/disc"
	inventory := testInventory(root,
		"BDMV/PLAYLIST/00000.mpls", "BDMV/STREAM/00000.m2ts",
	)
	identifier := fixtureIdentifier{
		filepath.Join(root, "BDMV/PLAYLIST/00000.mpls"): {
			DurationMS: 90 * 60 * 1000,
			ClipPaths:  []string{"/other-disc/BDMV/STREAM/00000.m2ts"},
		},
	}
	candidates, err := ListFeaturePlaylists(context.Background(), inventory, identifier)
	if err != nil {
		t.Fatal(err)
	}
	if len(candidates) != 0 {
		t.Errorf("accepted a playlist referring outside the download: %v", candidates)
	}
}

func testInventory(root string, paths ...string) controller.FileInventory {
	inventory := controller.FileInventory{}
	for _, path := range paths {
		id := controller.FileID(path)
		inventory.Files = append(inventory.Files, controller.InventoryFile{
			ID:             id,
			PathComponents: strings.Split(path, "/"),
			Fingerprint:    controller.FileFingerprint{SizeBytes: 100},
			DownloadFile: &controller.DownloadFileReference{
				LengthBytes: 100, BytesCompleted: 100, Selected: true,
			},
		})
		inventory.Paths = append(inventory.Paths, controller.FilePathMapping{
			FileID: id, AbsolutePath: filepath.Join(root, path),
		})
	}
	return inventory
}

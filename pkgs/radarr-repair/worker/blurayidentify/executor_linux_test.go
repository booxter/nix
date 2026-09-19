package blurayidentify

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/mkvmerge"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

type testFiles struct{ path string }

func (files testFiles) Open(_ string, _ []string, _ string) (*os.File, error) {
	return os.Open(files.path)
}

func (testFiles) Verify(_ *os.File, _ string) error { return nil }

func (files testFiles) AbsolutePath(_ string, _ []string) (string, error) {
	return files.path, nil
}

type testIdentifier struct{ playlist mkvmerge.Playlist }

func (identifier testIdentifier) Identify(_ context.Context, _ mkvmerge.Target) (mkvmerge.Playlist, error) {
	return identifier.playlist, nil
}

func TestExecutorReturnsOnlyDiscLocalClipNames(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	playlistPath := filepath.Join(root, "BDMV", "PLAYLIST", "00000.mpls")
	if err := os.MkdirAll(filepath.Dir(playlistPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(playlistPath, []byte("playlist"), 0o600); err != nil {
		t.Fatal(err)
	}
	clipPath := filepath.Join(root, "BDMV", "STREAM", "00000.m2ts")
	executor, err := NewExecutor(testFiles{path: playlistPath}, testIdentifier{
		playlist: mkvmerge.Playlist{
			DurationMS: 5_629_498, Chapters: 5, ClipPaths: []string{clipPath},
			Tracks: []mkvmerge.Track{{Kind: "video", Codec: "AVC"}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	request := workercontracts.BlurayIdentifyRequestV1{
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
		Operation:     workercontracts.IdentifyBlurayV1,
		RequestID:     "request:bluray:test", RootID: "root:downloads",
		PathComponents:      []string{"BDMV", "PLAYLIST", "00000.mpls"},
		ExpectedFingerprint: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
	}
	response := executor.Execute(context.Background(), request)
	if response.Success == nil || response.Success.DurationMS != 5_629_498 ||
		len(response.Success.ClipNames) != 1 || response.Success.ClipNames[0] != "00000.m2ts" {
		t.Fatalf("identified playlist = %#v", response)
	}
	if _, err := workercontracts.EncodeBlurayIdentifyResponse(response); err != nil {
		t.Fatalf("response does not satisfy wire contract: %v", err)
	}

	executor.identifier = testIdentifier{playlist: mkvmerge.Playlist{
		DurationMS: 5_629_498, ClipPaths: []string{"/other/BDMV/STREAM/00000.m2ts"},
		Tracks: []mkvmerge.Track{{Kind: "video", Codec: "AVC"}},
	}}
	if rejected := executor.Execute(context.Background(), request); rejected.Failure == nil ||
		rejected.Failure.Reason != "invalid_output" {
		t.Fatalf("accepted a clip outside the disc: %#v", rejected)
	}
}

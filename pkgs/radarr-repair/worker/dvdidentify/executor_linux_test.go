package dvdidentify

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/dvdvideo"
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

type testIdentifier struct {
	titles []dvdvideo.Title
	path   string
}

func (identifier *testIdentifier) Identify(_ context.Context, path string) ([]dvdvideo.Title, error) {
	identifier.path = path
	return identifier.titles, nil
}

func TestIdentifyDVDReturnsBoundedTitleEvidence(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	ifo := filepath.Join(root, "Movie", "VIDEO_TS", "VIDEO_TS.IFO")
	if err := os.MkdirAll(filepath.Dir(ifo), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ifo, []byte("ifo"), 0o600); err != nil {
		t.Fatal(err)
	}
	identifier := &testIdentifier{titles: []dvdvideo.Title{{
		Number: 1, DurationMS: 9_779_000, Chapters: 12, Angles: 1,
		TitleSet: 1, TitleInSet: 1,
		Tracks: []dvdvideo.Track{{Kind: "video", Codec: "mpeg2video"}, {Kind: "audio", Codec: "ac3"}},
	}}}
	executor, err := NewExecutor(testFiles{path: ifo}, identifier)
	if err != nil {
		t.Fatal(err)
	}
	request := workercontracts.DVDIdentifyRequestV1{
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
		Operation:     workercontracts.IdentifyDVDV1,
		RequestID:     "request:dvd:test", RootID: "root:downloads",
		PathComponents:      []string{"Movie", "VIDEO_TS", "VIDEO_TS.IFO"},
		ExpectedFingerprint: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
	}
	response := executor.Execute(context.Background(), request)
	if response.Success == nil || len(response.Success.Titles) != 1 ||
		response.Success.Titles[0].DurationMS != 9_779_000 ||
		response.Success.Titles[0].ChapterCount != 12 ||
		len(response.Success.Titles[0].Tracks) != 2 ||
		identifier.path != filepath.Dir(ifo) {
		t.Fatalf("DVD identification = %#v, directory = %q", response, identifier.path)
	}
	if _, err := workercontracts.EncodeDVDIdentifyResponse(response); err != nil {
		t.Fatalf("DVD identification does not satisfy wire contract: %v", err)
	}
	request.PathComponents = []string{"Movie", "VIDEO_TS", "VTS_01_1.VOB"}
	if rejected := executor.Execute(context.Background(), request); rejected.Failure == nil ||
		rejected.Failure.Reason != "invalid_path" {
		t.Fatalf("accepted VOB as DVD navigation root: %#v", rejected)
	}
}

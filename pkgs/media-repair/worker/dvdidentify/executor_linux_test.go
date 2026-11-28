package dvdidentify

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
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

func (identifier *testIdentifier) IdentifyDVD(_ context.Context, target dvdvideo.Target) ([]dvdvideo.Title, error) {
	identifier.path = target.NavigationPath
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
		Overlaps: []dvdvideo.Overlap{{Title: 2, SharedDurationMS: 9_000_000,
			Ranges: []dvdvideo.OverlapRange{{StartMS: 1_000, OtherStartMS: 0, DurationMS: 9_000_000}},
		}},
	}}}
	other := identifier.titles[0]
	other.Number, other.TitleInSet, other.Overlaps = 2, 2, nil
	identifier.titles = append(identifier.titles, other)
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
	if response.Success == nil || len(response.Success.Titles) != 2 ||
		response.Success.Titles[0].DurationMS != 9_779_000 ||
		response.Success.Titles[0].ChapterCount != 12 ||
		len(response.Success.Titles[0].Tracks) != 2 ||
		identifier.path != ifo {
		t.Fatalf("DVD identification = %#v, navigation path = %q", response, identifier.path)
	}
	data, err := workercontracts.EncodeDVDIdentifyResponse(response)
	if err != nil {
		t.Fatalf("DVD identification does not satisfy wire contract: %v", err)
	}
	decoded, err := workercontracts.DecodeDVDIdentifyResponse(data)
	if err != nil || decoded.Success == nil || len(decoded.Success.Titles[0].Overlaps) != 1 {
		t.Fatalf("DVD overlap lost in wire response: %+v, %v", decoded, err)
	}
	overlap := decoded.Success.Titles[0].Overlaps[0]
	if overlap.Title != 2 || overlap.SharedDurationMS != 9_000_000 || len(overlap.Ranges) != 1 ||
		overlap.Ranges[0].StartMS != 1_000 || overlap.Ranges[0].OtherStartMS != 0 || overlap.Ranges[0].DurationMS != 9_000_000 {
		t.Fatalf("DVD overlap changed in wire response: %+v", overlap)
	}
	request.PathComponents = []string{"Movie", "VIDEO_TS.IFO"}
	if flat := executor.Execute(context.Background(), request); flat.Success == nil {
		t.Fatalf("flat DVD identification = %#v", flat)
	}
	request.PathComponents = []string{"Movie", "VIDEO_TS", "VTS_01_1.VOB"}
	if rejected := executor.Execute(context.Background(), request); rejected.Failure == nil ||
		rejected.Failure.Reason != "invalid_path" {
		t.Fatalf("accepted VOB as DVD navigation root: %#v", rejected)
	}
}

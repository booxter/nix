package dvdstage

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
	"golang.org/x/sys/unix"
)

type testIdentifier struct{ title dvdvideo.Title }

func (identifier testIdentifier) IdentifyDVD(
	_ context.Context, _ dvdvideo.Target,
) ([]dvdvideo.Title, error) {
	return []dvdvideo.Title{identifier.title}, nil
}

type testRemuxer struct{ calls int }

func (remuxer *testRemuxer) RemuxDVD(
	_ context.Context, _ string, _ int, output *os.File,
) (int64, error) {
	remuxer.calls++
	size, err := output.Write([]byte("staged-matroska"))
	return int64(size), err
}

type testProber struct{}

func (testProber) ProbeFile(
	_ context.Context, _ *os.File,
) (controller.ProbeEvidence, error) {
	duration, chapterEnd := int64(9_788_385), int64(9_779_000)
	video, audio := controller.ProbeStreamVideo, controller.ProbeStreamAudio
	videoCodec, audioCodec := "mpeg2video", "ac3"
	chapters := make([]controller.ProbeChapter, 12)
	chapters[11].EndTimeMS = &chapterEnd
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{Names: []string{"matroska"}, DurationMS: &duration},
		Streams: []controller.ProbeStream{
			{Kind: &video, CodecName: &videoCodec},
			{Kind: &audio, CodecName: &audioCodec},
		},
		Chapters: chapters,
	}, nil
}

func TestStageOrRecoverBindsCompleteDVDDirectory(t *testing.T) {
	t.Parallel()
	root, spec, title, vobPath := stagedDVD(t)
	defer root.Close()
	remuxer := &testRemuxer{}
	executor, err := NewExecutor(root, root, testIdentifier{title}, remuxer, testProber{})
	if err != nil {
		t.Fatal(err)
	}
	first, err := executor.StageOrRecover(context.Background(), spec)
	if err != nil || first.SizeBytes != int64(len("staged-matroska")) ||
		first.ArtifactID == "" || first.Fingerprint == "" || remuxer.calls != 1 {
		t.Fatalf("DVD stage = %#v, calls = %d, error = %v", first, remuxer.calls, err)
	}
	second, err := executor.StageOrRecover(context.Background(), spec)
	if err != nil || !reflect.DeepEqual(second, first) || remuxer.calls != 1 {
		t.Fatalf("DVD recovery = %#v, calls = %d, error = %v", second, remuxer.calls, err)
	}
	if err := os.WriteFile(vobPath, []byte("changed media"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := executor.StageOrRecover(context.Background(), spec); err == nil {
		t.Fatal("recovered DVD output after a VOB changed")
	}
}

func TestStageRejectsUnboundDVDFile(t *testing.T) {
	t.Parallel()
	root, spec, title, vobPath := stagedDVD(t)
	defer root.Close()
	if err := os.WriteFile(filepath.Join(filepath.Dir(vobPath), "VTS_01_2.VOB"),
		[]byte("unbound media"), 0o600); err != nil {
		t.Fatal(err)
	}
	remuxer := &testRemuxer{}
	executor, err := NewExecutor(root, root, testIdentifier{title}, remuxer, testProber{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := executor.StageOrRecover(context.Background(), spec); err == nil || remuxer.calls != 0 {
		t.Fatalf("unbound DVD file was remuxed: calls = %d, error = %v", remuxer.calls, err)
	}
	artifactID, err := ArtifactID(spec)
	if err != nil {
		t.Fatal(err)
	}
	status, completed, err := root.InspectStaged(spec.RootID, artifactID,
		workercontracts.OutputContainerMKV)
	if completed != nil {
		_ = completed.Close()
	}
	if err != nil || status != mediafile.StagedMissing {
		t.Fatalf("unbound DVD source left an artifact: %d, %v", status, err)
	}
}

func stagedDVD(t *testing.T) (*mediafile.RootSet, Specification, dvdvideo.Title, string) {
	t.Helper()
	rootPath := t.TempDir()
	directory := filepath.Join(rootPath, "Movie", "VIDEO_TS")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	spec := Specification{
		ExecutionID: "execution:dvd", CaseID: "case:dvd", CapabilityID: "capability:dvd",
		RootID: "root:downloads", TitleNumber: 1,
		ExpectedDurationMS: 9_779_000, ExpectedChapterCount: 12,
		ExpectedTracks: []dvdvideo.Track{
			{Kind: "video", Codec: "mpeg2video"}, {Kind: "audio", Codec: "ac3"},
		},
	}
	for _, name := range []string{"VIDEO_TS.BUP", "VIDEO_TS.IFO", "VTS_01_1.VOB"} {
		path := filepath.Join(directory, name)
		if err := os.WriteFile(path, []byte("test media"), 0o600); err != nil {
			t.Fatal(err)
		}
		source := Source{PathComponents: []string{"Movie", "VIDEO_TS", name},
			ExpectedFingerprint: fingerprint(t, path), SizeBytes: int64(len("test media"))}
		spec.Sources = append(spec.Sources, source)
		if name == "VIDEO_TS.IFO" {
			spec.Navigation = source
		}
	}
	root, err := mediafile.NewRootSet(map[string]string{"root:downloads": rootPath})
	if err != nil {
		t.Fatal(err)
	}
	title := dvdvideo.Title{Number: 1, DurationMS: spec.ExpectedDurationMS,
		Chapters: 12, Angles: 1, TitleSet: 1, TitleInSet: 1,
		Tracks: spec.ExpectedTracks}
	return root, spec, title, filepath.Join(directory, "VTS_01_1.VOB")
}

func fingerprint(t *testing.T, path string) string {
	t.Helper()
	var stat unix.Stat_t
	if err := unix.Stat(path, &stat); err != nil {
		t.Fatal(err)
	}
	return (fileidentity.Snapshot{Device: uint64(stat.Dev), Inode: stat.Ino,
		SizeBytes: stat.Size,
		MTimeNS:   stat.Mtim.Sec*1_000_000_000 + stat.Mtim.Nsec}).StrictFingerprint()
}

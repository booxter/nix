package bluraystage

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/fileidentity"
	"github.com/booxter/nix-config/radarr-repair/internal/mkvmerge"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
	"golang.org/x/sys/unix"
)

type identifyingPlaylist struct{ details mkvmerge.Playlist }

func (identifier identifyingPlaylist) Identify(
	_ context.Context, _ mkvmerge.Target,
) (mkvmerge.Playlist, error) {
	return identifier.details, nil
}

type writingRemuxer struct {
	calls      int
	afterWrite func()
}

func (remuxer *writingRemuxer) Remux(
	_ context.Context, _ string, output *os.File,
) (int64, error) {
	remuxer.calls++
	size, err := output.Write([]byte("staged-matroska"))
	if remuxer.afterWrite != nil {
		remuxer.afterWrite()
	}
	return int64(size), err
}

type evidenceProber struct{ evidence controller.ProbeEvidence }

func (prober evidenceProber) ProbeFile(
	_ context.Context, _ *os.File,
) (controller.ProbeEvidence, error) {
	return prober.evidence, nil
}

func TestStageOrRecoverRemuxesOnceAndRevalidatesSources(t *testing.T) {
	t.Parallel()
	root, spec, details := stagedDisc(t)
	defer root.Close()
	remuxer := &writingRemuxer{}
	executor, err := NewExecutor(
		root, root, identifyingPlaylist{details}, remuxer,
		evidenceProber{validEvidence()},
	)
	if err != nil {
		t.Fatal(err)
	}
	first, err := executor.StageOrRecover(context.Background(), spec)
	if err != nil || first.SizeBytes != int64(len("staged-matroska")) ||
		first.ArtifactID == "" || first.Fingerprint == "" || remuxer.calls != 1 {
		t.Fatalf("stage result = %#v, calls = %d, error = %v", first, remuxer.calls, err)
	}
	second, err := executor.StageOrRecover(context.Background(), spec)
	if err != nil || !reflect.DeepEqual(second, first) || remuxer.calls != 1 {
		t.Fatalf("recovery result = %#v, calls = %d, error = %v", second, remuxer.calls, err)
	}
	clipPath, err := root.AbsolutePath(spec.RootID, spec.Clips[0].PathComponents)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(clipPath, []byte("different media"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := executor.StageOrRecover(context.Background(), spec); err == nil {
		t.Fatal("recovered output after the source clip changed")
	}
}

func TestStageRejectsInvalidOutputBeforeRetaining(t *testing.T) {
	t.Parallel()
	root, spec, details := stagedDisc(t)
	defer root.Close()
	evidence := validEvidence()
	wrongDuration := int64(50_000)
	evidence.Format.DurationMS = &wrongDuration
	executor, err := NewExecutor(
		root, root, identifyingPlaylist{details}, &writingRemuxer{},
		evidenceProber{evidence},
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := executor.StageOrRecover(context.Background(), spec); err == nil {
		t.Fatal("accepted remux output with incorrect duration")
	}
	artifactID, err := ArtifactID(spec)
	if err != nil {
		t.Fatal(err)
	}
	status, completed, err := root.InspectStaged(
		spec.RootID, artifactID, workercontracts.OutputContainerMKV,
	)
	if completed != nil {
		_ = completed.Close()
	}
	if err != nil || status != mediafile.StagedMissing {
		t.Fatalf("invalid output remains staged: status = %d, error = %v", status, err)
	}
}

func TestStageRejectsClipChangedDuringRemux(t *testing.T) {
	t.Parallel()
	root, spec, details := stagedDisc(t)
	defer root.Close()
	clipPath, err := root.AbsolutePath(spec.RootID, spec.Clips[0].PathComponents)
	if err != nil {
		t.Fatal(err)
	}
	remuxer := &writingRemuxer{afterWrite: func() {
		if err := os.WriteFile(clipPath, []byte("changed during remux"), 0o600); err != nil {
			t.Fatal(err)
		}
	}}
	executor, err := NewExecutor(
		root, root, identifyingPlaylist{details}, remuxer,
		evidenceProber{validEvidence()},
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := executor.StageOrRecover(context.Background(), spec); err == nil {
		t.Fatal("accepted remux after source clip changed")
	}
	artifactID, err := ArtifactID(spec)
	if err != nil {
		t.Fatal(err)
	}
	status, completed, err := root.InspectStaged(
		spec.RootID, artifactID, workercontracts.OutputContainerMKV,
	)
	if completed != nil {
		_ = completed.Close()
	}
	if err != nil || status != mediafile.StagedMissing {
		t.Fatalf("changed source left staged output: status = %d, error = %v", status, err)
	}
}

func stagedDisc(t *testing.T) (*mediafile.RootSet, Specification, mkvmerge.Playlist) {
	t.Helper()
	directory := t.TempDir()
	for _, path := range []string{"Movie/BDMV/PLAYLIST", "Movie/BDMV/STREAM"} {
		if err := os.MkdirAll(filepath.Join(directory, path), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	playlistParts := []string{"Movie", "BDMV", "PLAYLIST", "00000.mpls"}
	clipParts := []string{"Movie", "BDMV", "STREAM", "00000.m2ts"}
	playlistPath := filepath.Join(append([]string{directory}, playlistParts...)...)
	clipPath := filepath.Join(append([]string{directory}, clipParts...)...)
	for _, path := range []string{playlistPath, clipPath} {
		if err := os.WriteFile(path, []byte("test media"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	root, err := mediafile.NewRootSet(map[string]string{"root:downloads": directory})
	if err != nil {
		t.Fatal(err)
	}
	spec := Specification{
		ExecutionID: "execution:test", CaseID: "case:test",
		CapabilityID: "capability:test", RootID: "root:downloads",
		Playlist: Source{
			PathComponents: playlistParts, ExpectedFingerprint: fingerprint(t, playlistPath),
			SizeBytes: int64(len("test media")),
		},
		Clips: []Source{{
			PathComponents: clipParts, ExpectedFingerprint: fingerprint(t, clipPath),
			SizeBytes: int64(len("test media")),
		}},
		ExpectedDurationMS: 60_000, ExpectedChapterCount: 1,
		ExpectedTracks: []mkvmerge.Track{{Kind: "video", Codec: "H.264"}},
	}
	details := mkvmerge.Playlist{
		DurationMS: 60_000, Chapters: 1,
		ClipPaths: []string{clipPath}, Tracks: spec.ExpectedTracks,
	}
	return root, spec, details
}

func validEvidence() controller.ProbeEvidence {
	duration := int64(60_000)
	kind := controller.ProbeStreamVideo
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names: []string{"matroska", "webm"}, DurationMS: &duration,
		},
		Streams:  []controller.ProbeStream{{Kind: &kind}},
		Chapters: []controller.ProbeChapter{{ID: 1}},
	}
}

func fingerprint(t *testing.T, path string) string {
	t.Helper()
	var stat unix.Stat_t
	if err := unix.Stat(path, &stat); err != nil {
		t.Fatal(err)
	}
	return (fileidentity.Snapshot{
		Device: uint64(stat.Dev), Inode: stat.Ino,
		SizeBytes: stat.Size,
		MTimeNS:   stat.Mtim.Sec*1_000_000_000 + stat.Mtim.Nsec,
	}).Fingerprint()
}

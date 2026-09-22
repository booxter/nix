package materialize

import (
	"archive/tar"
	"context"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

type fakeFiles struct {
	root        string
	archive     string
	verifyCalls int
}

func (files *fakeFiles) Open(_ string, _ []string, _ string) (*os.File, error) {
	return os.Open(files.archive)
}

func (files *fakeFiles) Path(_ string) (string, error) {
	return files.root, nil
}

func (files *fakeFiles) Verify(_ *os.File, _ string) error {
	files.verifyCalls++
	return nil
}

type fakeProber struct {
	paths []string
}

func (prober *fakeProber) Probe(_ context.Context, path string) (controller.ProbeEvidence, error) {
	prober.paths = append(prober.paths, path)
	return controller.ProbeEvidence{}, nil
}

func TestMaterializeTarAudio(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, workspaceDirectory), 0o750); err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(root, "release.tar")
	writeTar(t, archive, []tarEntry{
		{name: "release/", typeflag: tar.TypeDir},
		{name: "release/cover.jpg", body: "cover"},
		{name: "release/02.flac", body: "second"},
		{name: "release/01.flac", body: "first"},
	})
	probeWorkspaceSetup(t, root)
	files := &fakeFiles{root: root, archive: archive}
	prober := &fakeProber{}
	executor, err := NewExecutor(files, prober)
	if err != nil {
		t.Fatal(err)
	}
	response := executor.Execute(context.Background(), validRequest())
	if response.Success == nil || response.Failure != nil {
		t.Fatalf("response = %#v, failure = %#v", response, response.Failure)
	}
	retry := validRequest()
	retry.RequestID = "request:retry"
	retried := executor.Execute(context.Background(), retry)
	if retried.Success == nil || retried.Success.RequestID != retry.RequestID || retried.Failure != nil {
		t.Fatalf("retried response = %#v, failure = %#v", retried, retried.Failure)
	}
	if files.verifyCalls != 2 || len(response.Success.Artifacts) != 2 || len(prober.paths) != 2 {
		t.Fatalf("verify calls = %d, response = %#v, probes = %v", files.verifyCalls, response, prober.paths)
	}
	if response.Success.Artifacts[0].RelativePath != "release/01.flac" ||
		response.Success.Artifacts[1].RelativePath != "release/02.flac" {
		t.Fatalf("artifacts = %#v", response.Success.Artifacts)
	}
	workspace := filepath.Join(root, workspaceDirectory, "workspaces", "workspace:test")
	for _, relative := range []string{"release/01.flac", "release/02.flac"} {
		info, err := os.Stat(filepath.Join(workspace, relative))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o640 {
			t.Fatalf("mode for %s = %o", relative, info.Mode().Perm())
		}
	}
}

func TestMaterializeRejectsArchiveLinks(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, workspaceDirectory), 0o750); err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(root, "release.tar")
	output, err := os.Create(archive)
	if err != nil {
		t.Fatal(err)
	}
	writer := tar.NewWriter(output)
	if err := writer.WriteHeader(&tar.Header{Name: "track.flac", Typeflag: tar.TypeSymlink, Linkname: "elsewhere"}); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := output.Close(); err != nil {
		t.Fatal(err)
	}
	probeWorkspaceSetup(t, root)
	executor, err := NewExecutor(&fakeFiles{root: root, archive: archive}, &fakeProber{})
	if err != nil {
		t.Fatal(err)
	}
	response := executor.Execute(context.Background(), validRequest())
	if response.Failure == nil || response.Failure.Reason != "invalid_archive" {
		t.Fatalf("response = %#v, failure = %#v", response, response.Failure)
	}
}

func probeWorkspaceSetup(t *testing.T, root string) {
	t.Helper()
	completed := filepath.Join(root, workspaceDirectory, "workspaces", "probe")
	partial := completed + ".partial"
	groupID, err := workspaceGroup(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := prepareWorkspace(root, partial, completed, groupID); err != nil {
		t.Fatalf("prepare workspace: %v", err)
	}
	if err := os.RemoveAll(filepath.Dir(completed)); err != nil {
		t.Fatal(err)
	}
}

func TestSafeArchiveName(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"../track.flac", "/track.flac", "dir/../track.flac", "dir\\track.flac"} {
		if _, err := safeArchiveName(name, false); err == nil {
			t.Fatalf("unsafe path accepted: %q", name)
		}
	}
	if got, err := safeArchiveName("album/01.flac", false); err != nil || got != "album/01.flac" {
		t.Fatalf("safe path = %q, %v", got, err)
	}
	if got, err := safeArchiveName("album/", true); err != nil || got != "album" {
		t.Fatalf("safe directory = %q, %v", got, err)
	}
	if _, err := safeArchiveName("album/", false); err == nil {
		t.Fatal("file path with trailing slash accepted")
	}
}

type tarEntry struct {
	name     string
	body     string
	typeflag byte
}

func writeTar(t *testing.T, path string, entries []tarEntry) {
	t.Helper()
	output, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	writer := tar.NewWriter(output)
	for _, entry := range entries {
		typeflag := entry.typeflag
		if typeflag == 0 {
			typeflag = tar.TypeReg
		}
		if err := writer.WriteHeader(&tar.Header{
			Name: entry.name, Mode: 0o644, Size: int64(len(entry.body)), Typeflag: typeflag,
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(writer, entry.body); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := output.Close(); err != nil {
		t.Fatal(err)
	}
}

func validRequest() Request {
	return Request{
		SchemaVersion:       SchemaVersion,
		RequestID:           "request:test",
		Operation:           OperationMaterializeTar,
		RootID:              "root:test",
		ArchiveComponents:   []string{"release.tar"},
		ExpectedFingerprint: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
		WorkspaceID:         "workspace:test",
	}
}

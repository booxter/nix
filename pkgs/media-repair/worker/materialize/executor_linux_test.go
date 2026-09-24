package materialize

import (
	"archive/tar"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"golang.org/x/sys/unix"
)

type fakeFiles struct {
	root        string
	archive     string
	verifyCalls int
}

func (files *fakeFiles) Open(_ string, components []string, _ string) (*os.File, error) {
	if files.archive != "" {
		return os.Open(files.archive)
	}
	return os.Open(filepath.Join(append([]string{files.root}, components...)...))
}

func TestMaterializeDirectoryAudio(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, workspaceDirectory), 0o750); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(root, "Artist", "Album")
	if err := os.MkdirAll(filepath.Join(source, "Disc 1"), 0o750); err != nil {
		t.Fatal(err)
	}
	for name, contents := range map[string]string{
		"02.flac":              "second",
		"Disc 1/01.flac":       "first",
		"cover.jpg":            "cover",
		"[private] \\junk.txt": "ignored",
	} {
		if err := os.WriteFile(filepath.Join(source, name), []byte(contents), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	probeWorkspaceSetup(t, root)
	files := &fakeFiles{root: root}
	prober := &fakeProber{}
	executor, err := NewExecutor(files, prober)
	if err != nil {
		t.Fatal(err)
	}
	request := Request{
		SchemaVersion: SchemaVersion, RequestID: "request:directory",
		Operation: OperationMaterializeDirectory, RootID: "root:test",
		SourceComponents: []string{"Artist", "Album"}, WorkspaceID: "workspace:directory",
	}
	response := executor.ExecuteDirectory(context.Background(), request)
	if response.Success == nil || response.Failure != nil {
		t.Fatalf("response = %#v, failure = %#v", response, response.Failure)
	}
	if response.Success.SourceFingerprint == "" || len(response.Success.Artifacts) != 2 ||
		response.Success.Artifacts[0].RelativePath != "02.flac" ||
		response.Success.Artifacts[1].RelativePath != "Disc 1/01.flac" {
		t.Fatalf("success = %#v", response.Success)
	}
	retry := request
	retry.RequestID = "request:retry"
	retried := executor.ExecuteDirectory(context.Background(), retry)
	if retried.Success == nil || retried.Success.RequestID != retry.RequestID ||
		len(prober.paths) != 2 {
		t.Fatalf("retried response = %#v, probes = %v", retried, prober.paths)
	}
	if err := os.WriteFile(filepath.Join(source, "03.flac"), []byte("third"), 0o640); err != nil {
		t.Fatal(err)
	}
	changed := request
	changed.RequestID = "request:changed"
	changedResponse := executor.ExecuteDirectory(context.Background(), changed)
	if changedResponse.Success == nil || len(changedResponse.Success.Artifacts) != 3 ||
		changedResponse.Success.SourceFingerprint == response.Success.SourceFingerprint {
		t.Fatalf("changed response = %#v", changedResponse)
	}
}

func TestMaterializeDirectoryRejectsSymlink(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, workspaceDirectory), 0o750); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(root, "Album")
	if err := os.Mkdir(source, 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("elsewhere.flac", filepath.Join(source, "track.flac")); err != nil {
		t.Fatal(err)
	}
	probeWorkspaceSetup(t, root)
	executor, err := NewExecutor(&fakeFiles{root: root}, &fakeProber{})
	if err != nil {
		t.Fatal(err)
	}
	response := executor.ExecuteDirectory(context.Background(), Request{
		SchemaVersion: SchemaVersion, RequestID: "request:directory",
		Operation: OperationMaterializeDirectory, RootID: "root:test",
		SourceComponents: []string{"Album"}, WorkspaceID: "workspace:directory",
	})
	if response.Failure == nil || response.Failure.Reason != "directory_contains_symlink" {
		t.Fatalf("response = %#v", response)
	}
}

func TestDirectoryFailuresRetainTheirStage(t *testing.T) {
	t.Parallel()

	tests := []struct {
		err  error
		want string
	}{
		{err: fmt.Errorf("%w: detail", errDirectoryCopy), want: "copy_failed"},
		{err: fmt.Errorf("%w: detail", errDirectoryProbe), want: "probe_failed"},
		{err: fmt.Errorf("%w: detail", errDirectoryChanged), want: "source_changed"},
		{err: fmt.Errorf("%w: detail", errDirectoryRead), want: "directory_read_failed"},
		{err: fmt.Errorf("%w: detail", errDirectoryEntry), want: "invalid_directory_entry"},
		{err: fmt.Errorf("%w: detail", errDirectorySymlink), want: "directory_contains_symlink"},
		{err: fmt.Errorf("%w: detail", errDirectorySpecial), want: "directory_contains_special_file"},
		{err: fmt.Errorf("%w: detail", errDirectoryLimit), want: "directory_limit_exceeded"},
		{err: fmt.Errorf("%w: detail", errDirectoryEntryInfo), want: "directory_entry_info_failed"},
		{err: errors.New("other"), want: "invalid_directory"},
	}
	for _, test := range tests {
		if got := reasonForDirectoryError(test.err); got != test.want {
			t.Errorf("reason = %q, want %q", got, test.want)
		}
	}
}

func TestDirectoryFingerprintIgnoresFilesystemDevice(t *testing.T) {
	t.Parallel()

	files := []directoryFile{{
		relative: "01.flac",
		snapshot: fileidentity.Snapshot{Device: 1, Inode: 2, SizeBytes: 3, MTimeNS: 4},
	}}
	before := directoryFingerprint(files)
	files[0].snapshot.Device++
	if after := directoryFingerprint(files); after != before {
		t.Fatalf("fingerprint changed from %q to %q", before, after)
	}
	files[0].snapshot.MTimeNS++
	if after := directoryFingerprint(files); after == before {
		t.Fatalf("changed file retained fingerprint %q", after)
	}
}

func (files *fakeFiles) OpenDirectory(_ string, components []string) (*os.File, error) {
	directory, err := os.Open(filepath.Join(append([]string{files.root}, components...)...))
	if err != nil {
		return nil, err
	}
	defer directory.Close()
	fd, err := unix.Dup(int(directory.Fd()))
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), "opaque-directory"), nil
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
	archiveInfo, err := os.Stat(archive)
	if err != nil {
		t.Fatal(err)
	}
	archiveSnapshot, err := fileidentity.FromFileInfo(archiveInfo)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := response.Success.SourceFingerprint, archiveSnapshot.StableFingerprint(); got != want {
		t.Fatalf("source fingerprint = %q, want %q", got, want)
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
	manifestPath := filepath.Join(workspace, workspaceManifest)
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	var stored manifest
	if err := json.Unmarshal(data, &stored); err != nil {
		t.Fatal(err)
	}
	stored.Version = "media-repair-workspace/v2"
	data, err = json.Marshal(stored)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(manifestPath, data, 0o600); err != nil {
		t.Fatal(err)
	}
	stalePath := filepath.Join(workspace, "stale")
	if err := os.WriteFile(stalePath, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	outdated := validRequest()
	outdated.RequestID = "request:outdated-workspace"
	rebuilt := executor.Execute(context.Background(), outdated)
	if rebuilt.Success == nil || rebuilt.Success.RequestID != outdated.RequestID ||
		rebuilt.Failure != nil || files.verifyCalls != 3 || len(prober.paths) != 4 {
		t.Fatalf(
			"rebuilt response = %#v, failure = %#v, verify calls = %d, probes = %v",
			rebuilt, rebuilt.Failure, files.verifyCalls, prober.paths,
		)
	}
	if _, err := os.Stat(stalePath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale workspace entry remains: %v", err)
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
		SourceComponents:    []string{"release.tar"},
		ExpectedFingerprint: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
		WorkspaceID:         "workspace:test",
	}
}

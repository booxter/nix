package materialize

import (
	"archive/tar"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
	"golang.org/x/sys/unix"
)

type fakeFiles struct {
	root    string
	archive string
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
	files := &fakeFiles{root: root}
	prober := &fakeProber{}
	executor, err := NewExecutor(files, prober, nil, nil)
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
	workspace := filepath.Join(root, workspaceDirectory, "workspaces", "workspace:directory")
	for relative, expected := range map[string]string{"02.flac": "second", "Disc 1/01.flac": "first"} {
		data, err := os.ReadFile(filepath.Join(workspace, relative))
		if err != nil || string(data) != expected {
			t.Fatalf("contents for %s = %q, error = %v", relative, data, err)
		}
	}
	retry := request
	retry.RequestID = "request:retry"
	prober.err = errors.New("probe unavailable")
	retried := executor.ExecuteDirectory(context.Background(), retry)
	if retried.Success == nil || retried.Success.RequestID != retry.RequestID {
		t.Fatalf("retried response = %#v", retried)
	}
	prober.err = nil
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

func TestDirectoryFailuresCleanWorkspace(t *testing.T) {
	t.Parallel()
	for _, reason := range []string{"directory_contains_symlink", "probe_failed", "source_changed"} {
		t.Run(reason, func(t *testing.T) {
			root := t.TempDir()
			if err := os.Mkdir(filepath.Join(root, workspaceDirectory), 0o750); err != nil {
				t.Fatal(err)
			}
			source := filepath.Join(root, "Album")
			if err := os.Mkdir(source, 0o750); err != nil {
				t.Fatal(err)
			}
			track := filepath.Join(source, "track.flac")
			prober := &fakeProber{}
			if reason == "directory_contains_symlink" {
				if err := os.Symlink("elsewhere.flac", track); err != nil {
					t.Fatal(err)
				}
			} else if err := os.WriteFile(track, []byte("audio"), 0o640); err != nil {
				t.Fatal(err)
			}
			if reason == "probe_failed" {
				prober.err = errors.New("probe failed")
			}
			if reason == "source_changed" {
				prober.onProbe = func() {
					replacement := track + ".replacement"
					if err := os.WriteFile(replacement, []byte("other"), 0o640); err != nil {
						t.Fatal(err)
					}
					if err := os.Rename(replacement, track); err != nil {
						t.Fatal(err)
					}
				}
			}
			executor, err := NewExecutor(&fakeFiles{root: root}, prober, nil, nil)
			if err != nil {
				t.Fatal(err)
			}
			response := executor.ExecuteDirectory(context.Background(), Request{
				SchemaVersion: SchemaVersion, RequestID: "request:directory",
				Operation: OperationMaterializeDirectory, RootID: "root:test",
				SourceComponents: []string{"Album"}, WorkspaceID: "workspace:directory",
			})
			if response.Failure == nil || response.Failure.Reason != reason {
				t.Fatalf("response = %#v", response)
			}
			entries, err := os.ReadDir(filepath.Join(root, workspaceDirectory, "workspaces"))
			if err != nil && !errors.Is(err, os.ErrNotExist) {
				t.Fatal(err)
			}
			if len(entries) != 0 {
				t.Fatalf("failed workspace left entries: %v", entries)
			}
		})
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

func (files *fakeFiles) Verify(file *os.File, fingerprint string) error {
	return (&mediafile.RootSet{}).Verify(file, fingerprint)
}

type fakeProber struct {
	err     error
	onProbe func()
}

func (prober *fakeProber) Probe(_ context.Context, _ string) (controller.ProbeEvidence, error) {
	if prober.onProbe != nil {
		prober.onProbe()
	}
	return controller.ProbeEvidence{}, prober.err
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
	files := &fakeFiles{root: root, archive: archive}
	prober := &fakeProber{}
	executor, err := NewExecutor(files, prober, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	response := executor.Execute(context.Background(), validRequest(t, archive))
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
	retry := validRequest(t, archive)
	retry.RequestID = "request:retry"
	prober.err = errors.New("probe unavailable")
	retried := executor.Execute(context.Background(), retry)
	if retried.Success == nil || retried.Success.RequestID != retry.RequestID || retried.Failure != nil {
		t.Fatalf("retried response = %#v, failure = %#v", retried, retried.Failure)
	}
	prober.err = nil
	if len(response.Success.Artifacts) != 2 {
		t.Fatalf("response = %#v", response)
	}
	if response.Success.Artifacts[0].RelativePath != "release/01.flac" ||
		response.Success.Artifacts[1].RelativePath != "release/02.flac" {
		t.Fatalf("artifacts = %#v", response.Success.Artifacts)
	}
	workspace := filepath.Join(root, workspaceDirectory, "workspaces", "workspace:test")
	for relative, expected := range map[string]string{"release/01.flac": "first", "release/02.flac": "second"} {
		data, err := os.ReadFile(filepath.Join(workspace, relative))
		if err != nil || string(data) != expected {
			t.Fatalf("contents for %s = %q, error = %v", relative, data, err)
		}
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
	outdated := validRequest(t, archive)
	outdated.RequestID = "request:outdated-workspace"
	rebuilt := executor.Execute(context.Background(), outdated)
	if rebuilt.Success == nil || rebuilt.Success.RequestID != outdated.RequestID ||
		rebuilt.Failure != nil {
		t.Fatalf("rebuilt response = %#v, failure = %#v", rebuilt, rebuilt.Failure)
	}
	if _, err := os.Stat(stalePath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale workspace entry remains: %v", err)
	}
}

func TestMaterializeTarVideo(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, workspaceDirectory), 0o750); err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(root, "release.tar")
	writeTar(t, archive, []tarEntry{
		{name: "Movie/cover.jpg", body: "cover"},
		{name: "Movie/movie.mkv", body: "video"},
	})
	prober := &fakeProber{}
	executor, err := NewExecutor(&fakeFiles{root: root, archive: archive}, prober, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	request := validRequest(t, archive)
	request.Operation = OperationMaterializeTarVideo
	request.WorkspaceID = "workspace:video"
	response := executor.Execute(context.Background(), request)
	if response.Success == nil || response.Failure != nil ||
		response.Success.Operation != OperationMaterializeTarVideo ||
		len(response.Success.Artifacts) != 1 ||
		response.Success.Artifacts[0].RelativePath != "Movie/movie.mkv" {
		t.Fatalf("response = %#v, failure = %#v", response, response.Failure)
	}
}

func TestMaterializeRejectsUnsafeArchiveEntries(t *testing.T) {
	t.Parallel()
	for name, entry := range map[string]tarEntry{
		"link":      {name: "track.flac", typeflag: tar.TypeSymlink},
		"traversal": {name: "../track.flac", body: "audio"},
		"absolute":  {name: "/track.flac", body: "audio"},
	} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			if err := os.Mkdir(filepath.Join(root, workspaceDirectory), 0o750); err != nil {
				t.Fatal(err)
			}
			archive := filepath.Join(root, "release.tar")
			writeTar(t, archive, []tarEntry{entry})
			executor, err := NewExecutor(
				&fakeFiles{root: root, archive: archive},
				&fakeProber{},
				nil,
				nil,
			)
			if err != nil {
				t.Fatal(err)
			}
			response := executor.Execute(context.Background(), validRequest(t, archive))
			if response.Failure == nil || response.Failure.Reason != "invalid_archive" {
				t.Fatalf("response = %#v, failure = %#v", response, response.Failure)
			}
		})
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

func validRequest(t *testing.T, archive string) Request {
	t.Helper()
	info, err := os.Stat(archive)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := fileidentity.FromFileInfo(info)
	if err != nil {
		t.Fatal(err)
	}
	return Request{
		SchemaVersion:       SchemaVersion,
		RequestID:           "request:test",
		Operation:           OperationMaterializeTar,
		RootID:              "root:test",
		SourceComponents:    []string{"release.tar"},
		ExpectedFingerprint: snapshot.StrictFingerprint(),
		WorkspaceID:         "workspace:test",
	}
}

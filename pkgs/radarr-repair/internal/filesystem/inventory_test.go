package filesystem

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

const inventoryTorrentHash = "abcdef0123456789abcdef0123456789abcdef01"

func TestInventoryReconcilesRegularFiles(t *testing.T) {
	t.Parallel()

	correlation := inventoryFixture(t)
	reader := New()
	inventory, err := reader.Inventory(context.Background(), correlation)
	if err != nil {
		t.Fatal(err)
	}
	if len(inventory.Files) != 3 || len(inventory.Paths) != 3 {
		t.Fatalf("files = %d, paths = %d", len(inventory.Files), len(inventory.Paths))
	}
	wantComponents := [][]string{
		{"CD1.mkv"},
		{"disc", "CD2.MKV"},
		{"extra.nfo"},
	}
	for index, file := range inventory.Files {
		if !reflect.DeepEqual(file.PathComponents, wantComponents[index]) {
			t.Fatalf("file %d components = %v", index, file.PathComponents)
		}
		if len(file.ID) != len("file:")+64 || strings.Contains(string(file.ID), file.PathComponents[0]) {
			t.Fatalf("file %d ID = %q", index, file.ID)
		}
		if file.Fingerprint.Inode == 0 || file.Fingerprint.SizeBytes <= 0 ||
			file.Fingerprint.MTimeNS == 0 {
			t.Fatalf("file %d fingerprint = %#v", index, file.Fingerprint)
		}
		if inventory.Paths[index].FileID != file.ID {
			t.Fatalf("path %d ID = %q, file ID = %q", index, inventory.Paths[index].FileID, file.ID)
		}
		wantPath := filepath.Join(correlation.DownloadRoot, filepath.FromSlash(
			strings.Join(file.PathComponents, "/"),
		))
		if inventory.Paths[index].AbsolutePath != wantPath {
			t.Fatalf("path %d = %q, want %q", index, inventory.Paths[index].AbsolutePath, wantPath)
		}
	}
	if inventory.Files[0].DownloadFile == nil || inventory.Files[0].DownloadFile.Index != 0 ||
		!inventory.Files[0].DownloadFile.Selected || inventory.Files[0].DownloadFile.LengthBytes != 3 {
		t.Fatalf("first torrent reference = %#v", inventory.Files[0].DownloadFile)
	}
	if inventory.Files[1].DownloadFile == nil || inventory.Files[1].DownloadFile.Index != 1 {
		t.Fatalf("second torrent reference = %#v", inventory.Files[1].DownloadFile)
	}
	if inventory.Files[2].DownloadFile != nil {
		t.Fatalf("extra file has torrent reference %#v", inventory.Files[2].DownloadFile)
	}

	again, err := reader.Inventory(context.Background(), correlation)
	if err != nil {
		t.Fatal(err)
	}
	for index := range inventory.Files {
		if again.Files[index].ID != inventory.Files[index].ID {
			t.Fatalf("file %d ID changed from %q to %q", index, inventory.Files[index].ID, again.Files[index].ID)
		}
	}
}

func TestInventoryReconcilesSingleFileTorrent(t *testing.T) {
	t.Parallel()

	parent := t.TempDir()
	name := "Single.Movie.mkv"
	path := filepath.Join(parent, name)
	if err := os.WriteFile(path, []byte("movie"), 0o600); err != nil {
		t.Fatal(err)
	}
	correlation := controller.DownloadCorrelation{
		DownloadRoot: path,
		Download: controller.Download{
			ID: inventoryTorrentHash, ContentOwnership: controller.DownloadContentManifest,
			Files: []controller.DownloadFile{
				{
					Index:          0,
					HasIndex:       true,
					Path:           path,
					LengthBytes:    5,
					BytesCompleted: 5,
					Selected:       true,
				},
			},
		},
	}
	inventory, err := New().Inventory(context.Background(), correlation)
	if err != nil {
		t.Fatal(err)
	}
	if len(inventory.Files) != 1 || len(inventory.Paths) != 1 {
		t.Fatalf("inventory = %#v", inventory)
	}
	if !reflect.DeepEqual(inventory.Files[0].PathComponents, []string{name}) ||
		inventory.Files[0].DownloadFile == nil ||
		inventory.Files[0].DownloadFile.Index != 0 ||
		inventory.Paths[0].AbsolutePath != path {
		t.Fatalf("inventory = %#v", inventory)
	}
}

func TestInventoryOwnsEveryFileInCompletedOutputTree(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	for relative, contents := range map[string]string{
		"Movie.mkv":   "movie",
		"Subs/en.srt": "subtitle",
	} {
		path := filepath.Join(root, filepath.FromSlash(relative))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	correlation := controller.DownloadCorrelation{
		DownloadRoot: root,
		Download: controller.Download{
			ID: "sab-id", ContentOwnership: controller.DownloadContentOutputTree,
		},
	}

	inventory, err := New().Inventory(context.Background(), correlation)
	if err != nil {
		t.Fatal(err)
	}
	if len(inventory.Files) != 2 {
		t.Fatalf("files = %#v", inventory.Files)
	}
	for _, file := range inventory.Files {
		if file.DownloadFile == nil || file.DownloadFile.HasIndex ||
			!file.DownloadFile.Selected ||
			file.DownloadFile.BytesCompleted != file.Fingerprint.SizeBytes ||
			file.DownloadFile.LengthBytes != file.Fingerprint.SizeBytes {
			t.Fatalf("output-tree file = %#v", file)
		}
	}
}

func TestInventoryOmitsPublishedRepairArtifacts(t *testing.T) {
	t.Parallel()

	correlation := inventoryFixture(t)
	repairName := "radarr-repair-" + strings.Repeat("a", 64) + ".mkv"
	if err := os.WriteFile(
		filepath.Join(correlation.DownloadRoot, repairName),
		[]byte("repair output"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}

	inventory, err := New().Inventory(context.Background(), correlation)
	if err != nil {
		t.Fatal(err)
	}
	if len(inventory.Files) != 3 {
		t.Fatalf("files = %#v", inventory.Files)
	}
	for _, file := range inventory.Files {
		if strings.Join(file.PathComponents, "/") == repairName {
			t.Fatalf("repair output was included: %#v", file)
		}
	}
}

func TestInventoryKeepsPublishedNameFromDownloadManifest(t *testing.T) {
	t.Parallel()

	correlation := inventoryFixture(t)
	repairName := "radarr-repair-" + strings.Repeat("a", 64) + ".mkv"
	contents := []byte("download content")
	path := filepath.Join(correlation.DownloadRoot, repairName)
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	correlation.Download.Files = append(correlation.Download.Files, controller.DownloadFile{
		Index:          3,
		HasIndex:       true,
		Path:           path,
		LengthBytes:    int64(len(contents)),
		BytesCompleted: int64(len(contents)),
		Selected:       true,
	})

	inventory, err := New().Inventory(context.Background(), correlation)
	if err != nil {
		t.Fatal(err)
	}
	if len(inventory.Files) != 4 {
		t.Fatalf("files = %#v", inventory.Files)
	}
	found := false
	for _, file := range inventory.Files {
		if strings.Join(file.PathComponents, "/") == repairName {
			found = file.DownloadFile != nil && file.DownloadFile.Index == 3
		}
	}
	if !found {
		t.Fatalf("manifest file %q was not included", repairName)
	}
}

func TestInventoryRejectsManifestForOutputTree(t *testing.T) {
	t.Parallel()

	correlation := inventoryFixture(t)
	correlation.Download.ContentOwnership = controller.DownloadContentOutputTree
	assertInventoryError(t, New(), correlation, "must not contain a source manifest")
}

func TestInventoryRejectsMismatchedSingleFileManifest(t *testing.T) {
	t.Parallel()

	parent := t.TempDir()
	path := filepath.Join(parent, "Single.Movie.mkv")
	if err := os.WriteFile(path, []byte("movie"), 0o600); err != nil {
		t.Fatal(err)
	}
	correlation := controller.DownloadCorrelation{
		DownloadRoot: path,
		Download: controller.Download{
			ID: inventoryTorrentHash, ContentOwnership: controller.DownloadContentManifest,
			Files: []controller.DownloadFile{
				{Index: 0, HasIndex: true, Path: filepath.Join(parent, "Other.Movie.mkv"), LengthBytes: 5, BytesCompleted: 5, Selected: true},
			},
		},
	}
	assertInventoryError(t, New(), correlation, "manifest does not match single-file download")
}

func TestInventoryRequiresWantedFilesAndMatchingSizes(t *testing.T) {
	t.Parallel()

	t.Run("missing wanted", func(t *testing.T) {
		t.Parallel()
		correlation := inventoryFixture(t)
		if err := os.Remove(filepath.Join(correlation.DownloadRoot, "CD1.mkv")); err != nil {
			t.Fatal(err)
		}
		assertInventoryError(t, New(), correlation, "selected download file \"CD1.mkv\" is missing")
	})

	t.Run("missing unwanted", func(t *testing.T) {
		t.Parallel()
		correlation := inventoryFixture(t)
		if _, err := New().Inventory(context.Background(), correlation); err != nil {
			t.Fatalf("missing unwanted file was rejected: %v", err)
		}
	})

	t.Run("size mismatch", func(t *testing.T) {
		t.Parallel()
		correlation := inventoryFixture(t)
		if err := os.WriteFile(filepath.Join(correlation.DownloadRoot, "CD1.mkv"), []byte("changed"), 0o600); err != nil {
			t.Fatal(err)
		}
		assertInventoryError(t, New(), correlation, "size does not match download manifest")
	})
}

func TestInventoryRejectsInvalidManifest(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*controller.DownloadCorrelation)
		want   string
	}{
		{
			name: "negative index",
			mutate: func(correlation *controller.DownloadCorrelation) {
				correlation.Download.Files[0].Index = -1
			},
			want: "index -1 is invalid",
		},
		{
			name: "duplicate index",
			mutate: func(correlation *controller.DownloadCorrelation) {
				correlation.Download.Files[1].Index = 0
			},
			want: "index 0 is duplicated",
		},
		{
			name: "relative path",
			mutate: func(correlation *controller.DownloadCorrelation) {
				correlation.Download.Files[0].Path = "CD1.mkv"
			},
			want: "path is invalid",
		},
		{
			name: "unclean path",
			mutate: func(correlation *controller.DownloadCorrelation) {
				correlation.Download.Files[0].Path = filepath.Join(correlation.DownloadRoot, "disc", "..", "CD1.mkv") + "/../CD1.mkv"
			},
			want: "path is not canonical",
		},
		{
			name: "outside root",
			mutate: func(correlation *controller.DownloadCorrelation) {
				correlation.Download.Files[0].Path = filepath.Join(filepath.Dir(correlation.DownloadRoot), "Other.Movie", "CD1.mkv")
			},
			want: "path is outside the download root",
		},
		{
			name: "duplicate path",
			mutate: func(correlation *controller.DownloadCorrelation) {
				correlation.Download.Files[1].Path = correlation.Download.Files[0].Path
			},
			want: "path \"CD1.mkv\" is duplicated",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			correlation := inventoryFixture(t)
			test.mutate(&correlation)
			assertInventoryError(t, New(), correlation, test.want)
		})
	}
}

func TestInventoryRejectsUnsafeFilesystemEntries(t *testing.T) {
	t.Parallel()

	t.Run("symlink", func(t *testing.T) {
		t.Parallel()
		correlation := inventoryFixture(t)
		if err := os.Symlink("CD1.mkv", filepath.Join(correlation.DownloadRoot, "link.mkv")); err != nil {
			t.Fatal(err)
		}
		assertInventoryError(t, New(), correlation, "is a symbolic link")
	})

	t.Run("named pipe", func(t *testing.T) {
		t.Parallel()
		correlation := inventoryFixture(t)
		if err := syscall.Mkfifo(filepath.Join(correlation.DownloadRoot, "pipe"), 0o600); err != nil {
			t.Fatal(err)
		}
		assertInventoryError(t, New(), correlation, "is not a regular file or directory")
	})

	t.Run("unreadable", func(t *testing.T) {
		t.Parallel()
		correlation := inventoryFixture(t)
		path := filepath.Join(correlation.DownloadRoot, "CD1.mkv")
		if err := os.Chmod(path, 0); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			_ = os.Chmod(path, 0o600)
		})
		assertInventoryError(t, New(), correlation, "open regular file")
	})

	t.Run("root symlink", func(t *testing.T) {
		t.Parallel()
		correlation := inventoryFixture(t)
		link := filepath.Join(filepath.Dir(correlation.DownloadRoot), "linked-root")
		if err := os.Symlink(correlation.DownloadRoot, link); err != nil {
			t.Fatal(err)
		}
		correlation.DownloadRoot = link
		assertInventoryError(t, New(), correlation, "download target is not a regular file or directory")
	})
}

func TestInventoryRejectsChangesDuringWalk(t *testing.T) {
	t.Parallel()

	correlation := inventoryFixture(t)
	target := filepath.Join(correlation.DownloadRoot, "CD1.mkv")
	reader := &Reader{
		openRoot: func(path string) (rootHandle, error) {
			root, err := os.OpenRoot(path)
			if err != nil {
				return nil, err
			}
			return &mutatingRoot{
				rootHandle: root,
				targetName: "CD1.mkv",
				targetPath: target,
			}, nil
		},
	}
	assertInventoryError(t, reader, correlation, "changed during inventory")
}

func TestInventoryRejectsInvalidInputs(t *testing.T) {
	t.Parallel()

	correlation := inventoryFixture(t)
	correlation.RejectionReasons = []controller.CorrelationRejectionReason{
		controller.CorrelationIncompleteDownload,
	}
	assertInventoryError(t, New(), correlation, "download correlation is ineligible")

	correlation = inventoryFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := New().Inventory(ctx, correlation)
	if err == nil || !strings.Contains(err.Error(), context.Canceled.Error()) {
		t.Fatalf("error = %v", err)
	}

	var reader *Reader
	assertInventoryError(t, reader, inventoryFixture(t), "filesystem reader is not configured")
}

type mutatingRoot struct {
	rootHandle
	targetName string
	targetPath string
	mutated    bool
}

func (root *mutatingRoot) Lstat(name string) (os.FileInfo, error) {
	if name == root.targetName && !root.mutated {
		root.mutated = true
		if err := os.WriteFile(root.targetPath, []byte("changed during inventory"), 0o600); err != nil {
			return nil, err
		}
	}
	return root.rootHandle.Lstat(name)
}

func inventoryFixture(t *testing.T) controller.DownloadCorrelation {
	t.Helper()
	parent := t.TempDir()
	root := filepath.Join(parent, "Example.Movie")
	if err := os.MkdirAll(filepath.Join(root, "disc"), 0o700); err != nil {
		t.Fatal(err)
	}
	for relative, contents := range map[string]string{
		"CD1.mkv":      "one",
		"disc/CD2.MKV": "two-two",
		"extra.nfo":    "metadata",
	} {
		if err := os.WriteFile(filepath.Join(root, filepath.FromSlash(relative)), []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return controller.DownloadCorrelation{
		DownloadRoot: root,
		Download: controller.Download{
			ID: inventoryTorrentHash, ContentOwnership: controller.DownloadContentManifest,
			Files: []controller.DownloadFile{
				{
					Index:          0,
					HasIndex:       true,
					Path:           filepath.Join(root, "CD1.mkv"),
					LengthBytes:    3,
					BytesCompleted: 3,
					Selected:       true,
				},
				{
					Index:          1,
					HasIndex:       true,
					Path:           filepath.Join(root, "disc", "CD2.MKV"),
					LengthBytes:    7,
					BytesCompleted: 7,
					Selected:       true,
				},
				{
					Index:          2,
					HasIndex:       true,
					Path:           filepath.Join(root, "optional.txt"),
					LengthBytes:    10,
					BytesCompleted: 0,
					Selected:       false,
				},
			},
		},
	}
}

func assertInventoryError(
	t *testing.T,
	reader *Reader,
	correlation controller.DownloadCorrelation,
	want string,
) {
	t.Helper()
	_, err := reader.Inventory(context.Background(), correlation)
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("error = %v, want substring %q", err, want)
	}
}

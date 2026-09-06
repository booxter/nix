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
	if inventory.Files[0].TorrentFile == nil || inventory.Files[0].TorrentFile.Index != 0 ||
		!inventory.Files[0].TorrentFile.Wanted || inventory.Files[0].TorrentFile.LengthBytes != 3 {
		t.Fatalf("first torrent reference = %#v", inventory.Files[0].TorrentFile)
	}
	if inventory.Files[1].TorrentFile == nil || inventory.Files[1].TorrentFile.Index != 1 {
		t.Fatalf("second torrent reference = %#v", inventory.Files[1].TorrentFile)
	}
	if inventory.Files[2].TorrentFile != nil {
		t.Fatalf("extra file has torrent reference %#v", inventory.Files[2].TorrentFile)
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

func TestInventoryRequiresWantedFilesAndMatchingSizes(t *testing.T) {
	t.Parallel()

	t.Run("missing wanted", func(t *testing.T) {
		t.Parallel()
		correlation := inventoryFixture(t)
		if err := os.Remove(filepath.Join(correlation.DownloadRoot, "CD1.mkv")); err != nil {
			t.Fatal(err)
		}
		assertInventoryError(t, New(), correlation, "wanted Transmission file \"CD1.mkv\" is missing")
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
		assertInventoryError(t, New(), correlation, "size does not match Transmission")
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
				correlation.Transmission.Files[0].Index = -1
			},
			want: "index -1 is invalid",
		},
		{
			name: "duplicate index",
			mutate: func(correlation *controller.DownloadCorrelation) {
				correlation.Transmission.Files[1].Index = 0
			},
			want: "index 0 is duplicated",
		},
		{
			name: "absolute path",
			mutate: func(correlation *controller.DownloadCorrelation) {
				correlation.Transmission.Files[0].Name = "/tmp/CD1.mkv"
			},
			want: "path is invalid",
		},
		{
			name: "unclean path",
			mutate: func(correlation *controller.DownloadCorrelation) {
				correlation.Transmission.Files[0].Name = "Example.Movie/disc/../CD1.mkv"
			},
			want: "path is not canonical",
		},
		{
			name: "outside root",
			mutate: func(correlation *controller.DownloadCorrelation) {
				correlation.Transmission.Files[0].Name = "Other.Movie/CD1.mkv"
			},
			want: "path is outside the download root",
		},
		{
			name: "duplicate path",
			mutate: func(correlation *controller.DownloadCorrelation) {
				correlation.Transmission.Files[1].Name = correlation.Transmission.Files[0].Name
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
		for index := range correlation.Transmission.Files {
			correlation.Transmission.Files[index].Name = strings.Replace(
				correlation.Transmission.Files[index].Name,
				"Example.Movie/",
				"linked-root/",
				1,
			)
		}
		assertInventoryError(t, New(), correlation, "download root is not a regular directory")
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
		controller.CorrelationIncompleteTorrent,
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
		Transmission: controller.TransmissionTorrent{
			Hash:              inventoryTorrentHash,
			DownloadDirectory: parent,
			Files: []controller.TransmissionFile{
				{
					Index:          0,
					Name:           "Example.Movie/CD1.mkv",
					LengthBytes:    3,
					BytesCompleted: 3,
					Wanted:         true,
				},
				{
					Index:          1,
					Name:           "Example.Movie/disc/CD2.MKV",
					LengthBytes:    7,
					BytesCompleted: 7,
					Wanted:         true,
				},
				{
					Index:          2,
					Name:           "Example.Movie/optional.txt",
					LengthBytes:    10,
					BytesCompleted: 0,
					Wanted:         false,
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

package mediafile

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/fileidentity"
	"golang.org/x/sys/unix"
)

func TestRootSetOpensNestedRegularFile(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	directory := filepath.Join(rootPath, "Movie")
	if err := os.Mkdir(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	mediaPath := filepath.Join(directory, "part.mkv")
	if err := os.WriteFile(mediaPath, []byte("media"), 0o600); err != nil {
		t.Fatal(err)
	}

	rootSet := testRootSet(t, rootPath)
	media, err := rootSet.Open(
		"downloads",
		[]string{"Movie", "part.mkv"},
		pathFingerprint(t, mediaPath),
	)
	if err != nil {
		t.Fatal(err)
	}
	defer media.Close()

	data, err := io.ReadAll(media)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "media" {
		t.Fatalf("media = %q", data)
	}
	if err := rootSet.Verify(media, pathFingerprint(t, mediaPath)); err != nil {
		t.Fatalf("verify open media: %v", err)
	}
}

func TestRootSetRejectsUnsafeAndUnavailablePaths(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	regularPath := filepath.Join(rootPath, "movie.mkv")
	if err := os.WriteFile(regularPath, []byte("media"), 0o600); err != nil {
		t.Fatal(err)
	}
	directoryPath := filepath.Join(rootPath, "directory")
	if err := os.Mkdir(directoryPath, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("movie.mkv", filepath.Join(rootPath, "link.mkv")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("directory", filepath.Join(rootPath, "link-directory")); err != nil {
		t.Fatal(err)
	}
	fifoPath := filepath.Join(rootPath, "fifo")
	if err := unix.Mkfifo(fifoPath, 0o600); err != nil {
		t.Fatal(err)
	}

	rootSet := testRootSet(t, rootPath)
	fingerprint := pathFingerprint(t, regularPath)
	tests := []struct {
		name        string
		rootID      string
		components  []string
		fingerprint string
		want        FailureKind
	}{
		{
			name: "unknown root", rootID: "other", components: []string{"movie.mkv"},
			fingerprint: fingerprint, want: FailureUnknownRoot,
		},
		{
			name: "empty path", rootID: "downloads", fingerprint: fingerprint,
			want: FailureInvalidPath,
		},
		{
			name: "parent traversal", rootID: "downloads", components: []string{"..", "movie.mkv"},
			fingerprint: fingerprint, want: FailureInvalidPath,
		},
		{
			name: "embedded separator", rootID: "downloads", components: []string{"directory/movie.mkv"},
			fingerprint: fingerprint, want: FailureInvalidPath,
		},
		{
			name: "final symlink", rootID: "downloads", components: []string{"link.mkv"},
			fingerprint: fingerprint, want: FailureInvalidPath,
		},
		{
			name: "intermediate symlink", rootID: "downloads", components: []string{"link-directory", "missing.mkv"},
			fingerprint: fingerprint, want: FailureInvalidPath,
		},
		{
			name: "missing file", rootID: "downloads", components: []string{"missing.mkv"},
			fingerprint: fingerprint, want: FailureFileUnavailable,
		},
		{
			name: "directory", rootID: "downloads", components: []string{"directory"},
			fingerprint: fingerprint, want: FailureNotRegularFile,
		},
		{
			name: "fifo", rootID: "downloads", components: []string{"fifo"},
			fingerprint: fingerprint, want: FailureNotRegularFile,
		},
		{
			name: "fingerprint mismatch", rootID: "downloads", components: []string{"movie.mkv"},
			fingerprint: "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
			want:        FailureFingerprintMismatch,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			media, err := rootSet.Open(test.rootID, test.components, test.fingerprint)
			if media != nil {
				_ = media.Close()
				t.Fatal("media file was opened")
			}
			assertFailureKind(t, err, test.want)
			joinedPath := strings.Join(test.components, "/")
			if strings.Contains(err.Error(), rootPath) ||
				(joinedPath != "" && strings.Contains(err.Error(), joinedPath)) {
				t.Fatalf("failure exposes media path: %v", err)
			}
		})
	}
}

func TestVerifyDetectsChangeAfterOpening(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	mediaPath := filepath.Join(rootPath, "movie.mkv")
	if err := os.WriteFile(mediaPath, []byte("media"), 0o600); err != nil {
		t.Fatal(err)
	}
	fingerprint := pathFingerprint(t, mediaPath)
	rootSet := testRootSet(t, rootPath)
	media, err := rootSet.Open("downloads", []string{"movie.mkv"}, fingerprint)
	if err != nil {
		t.Fatal(err)
	}
	defer media.Close()

	if err := os.WriteFile(mediaPath, []byte("changed media"), 0o600); err != nil {
		t.Fatal(err)
	}
	assertFailureKind(t, rootSet.Verify(media, fingerprint), FailureFingerprintMismatch)
}

func TestNewRootSetRejectsUnsafeRoot(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	rootLink := filepath.Join(t.TempDir(), "root-link")
	if err := os.Symlink(rootPath, rootLink); err != nil {
		t.Fatal(err)
	}
	if _, err := NewRootSet(map[string]string{"downloads": rootLink}); err == nil {
		t.Fatal("symlink root was accepted")
	}
	if _, err := NewRootSet(map[string]string{"downloads": "relative"}); err == nil {
		t.Fatal("relative root was accepted")
	}
}

func testRootSet(t *testing.T, rootPath string) *RootSet {
	t.Helper()
	rootSet, err := NewRootSet(map[string]string{"downloads": rootPath})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := rootSet.Close(); err != nil {
			t.Errorf("close roots: %v", err)
		}
	})
	return rootSet
}

func pathFingerprint(t *testing.T, path string) string {
	t.Helper()
	var stat unix.Stat_t
	if err := unix.Stat(path, &stat); err != nil {
		t.Fatal(err)
	}
	return fileidentity.Snapshot{
		Device:    uint64(stat.Dev),
		Inode:     stat.Ino,
		SizeBytes: stat.Size,
		MTimeNS:   stat.Mtim.Sec*1_000_000_000 + stat.Mtim.Nsec,
	}.Fingerprint()
}

func assertFailureKind(t *testing.T, err error, want FailureKind) {
	t.Helper()
	var failure *Failure
	if !errors.As(err, &failure) || failure.Kind != want {
		t.Fatalf("error = %v, want failure kind %v", err, want)
	}
}

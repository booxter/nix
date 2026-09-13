package mediafile

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"golang.org/x/sys/unix"
)

func TestStagedArtifactIsPrivateAndOnMediaFilesystem(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	rootSet := testRootSet(t, rootPath)
	artifact, err := rootSet.CreateStaged(
		"downloads",
		"artifact:test",
		workercontracts.OutputContainerMKV,
		1,
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := artifact.File().Write([]byte("joined media")); err != nil {
		t.Fatal(err)
	}
	fingerprint, sizeBytes, err := artifact.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if fingerprint == "" || sizeBytes != int64(len("joined media")) {
		t.Fatalf("snapshot = %q, %d", fingerprint, sizeBytes)
	}

	var rootStat unix.Stat_t
	if err := unix.Stat(rootPath, &rootStat); err != nil {
		t.Fatal(err)
	}
	var artifactStat unix.Stat_t
	if err := unix.Fstat(int(artifact.File().Fd()), &artifactStat); err != nil {
		t.Fatal(err)
	}
	if rootStat.Dev != artifactStat.Dev {
		t.Fatal("staged artifact is not on the media root filesystem")
	}
	if artifactStat.Mode&0o777 != 0o600 {
		t.Fatalf("staged artifact mode = %o", artifactStat.Mode&0o777)
	}
	if err := artifact.Retain(); err != nil {
		t.Fatal(err)
	}

	entries, err := os.ReadDir(filepath.Join(rootPath, workerDirectoryName, stagedDirectoryName))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("retained staged artifacts = %d, want 1", len(entries))
	}
}

func TestDiscardRemovesOnlyItsStagedArtifact(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	unrelatedPath := filepath.Join(rootPath, "unrelated.mkv")
	if err := os.WriteFile(unrelatedPath, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	rootSet := testRootSet(t, rootPath)
	artifact, err := rootSet.CreateStaged(
		"downloads",
		"artifact:discard",
		workercontracts.OutputContainerMKV,
		1,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := artifact.Discard(); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(unrelatedPath); err != nil || string(data) != "keep" {
		t.Fatalf("unrelated file = %q, error = %v", data, err)
	}
	entries, err := os.ReadDir(filepath.Join(rootPath, workerDirectoryName, stagedDirectoryName))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("staged artifacts after discard = %d", len(entries))
	}
}

func TestCreateStagedRejectsExistingArtifact(t *testing.T) {
	t.Parallel()

	rootSet := testRootSet(t, t.TempDir())
	artifact, err := rootSet.CreateStaged(
		"downloads",
		"artifact:same",
		workercontracts.OutputContainerMP4,
		1,
	)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = artifact.Discard() })

	duplicate, err := rootSet.CreateStaged(
		"downloads",
		"artifact:same",
		workercontracts.OutputContainerMP4,
		1,
	)
	if duplicate != nil {
		t.Fatal("existing staged artifact was replaced")
	}
	var failure *Failure
	if !errors.As(err, &failure) || failure.Kind != FailureArtifactExists {
		t.Fatalf("duplicate error = %v", err)
	}
}

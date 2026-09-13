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
	status, completed, err := rootSet.InspectStaged(
		"downloads",
		"artifact:test",
		workercontracts.OutputContainerMKV,
	)
	if err != nil {
		t.Fatal(err)
	}
	if status != StagedComplete || completed == nil {
		t.Fatalf("staged status = %v, artifact = %#v", status, completed)
	}
	t.Cleanup(func() { _ = completed.Close() })
	completedFingerprint, completedSize, err := completed.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if completedFingerprint != fingerprint || completedSize != sizeBytes {
		t.Fatalf("completed snapshot = %q, %d", completedFingerprint, completedSize)
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
		t.Fatalf("partial duplicate error = %v", err)
	}
	if err := artifact.Retain(); err != nil {
		t.Fatal(err)
	}
	duplicate, err = rootSet.CreateStaged(
		"downloads",
		"artifact:same",
		workercontracts.OutputContainerMP4,
		1,
	)
	if duplicate != nil {
		t.Fatal("completed staged artifact was replaced")
	}
	if !errors.As(err, &failure) || failure.Kind != FailureArtifactExists {
		t.Fatalf("completed duplicate error = %v", err)
	}
}

func TestInterruptedStagedArtifactCanBeDetectedAndRemoved(t *testing.T) {
	t.Parallel()

	rootSet := testRootSet(t, t.TempDir())
	status, completed, err := rootSet.InspectStaged(
		"downloads",
		"artifact:interrupted",
		workercontracts.OutputContainerMKV,
	)
	if err != nil || status != StagedMissing || completed != nil {
		t.Fatalf("initial inspection = %v, %#v, %v", status, completed, err)
	}

	artifact, err := rootSet.CreateStaged(
		"downloads",
		"artifact:interrupted",
		workercontracts.OutputContainerMKV,
		1,
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := artifact.File().Write([]byte("partial")); err != nil {
		t.Fatal(err)
	}
	abandonStagedArtifact(t, artifact)

	status, completed, err = rootSet.InspectStaged(
		"downloads",
		"artifact:interrupted",
		workercontracts.OutputContainerMKV,
	)
	if err != nil || status != StagedPartial || completed != nil {
		t.Fatalf("interrupted inspection = %v, %#v, %v", status, completed, err)
	}
	removed, err := rootSet.RemovePartial(
		"downloads",
		"artifact:interrupted",
		workercontracts.OutputContainerMKV,
	)
	if err != nil || !removed {
		t.Fatalf("remove partial = %t, %v", removed, err)
	}
	status, completed, err = rootSet.InspectStaged(
		"downloads",
		"artifact:interrupted",
		workercontracts.OutputContainerMKV,
	)
	if err != nil || status != StagedMissing || completed != nil {
		t.Fatalf("final inspection = %v, %#v, %v", status, completed, err)
	}
}

func TestRetainMakesOnlyCompletedArtifactVisible(t *testing.T) {
	t.Parallel()

	rootSet := testRootSet(t, t.TempDir())
	artifact, err := rootSet.CreateStaged(
		"downloads",
		"artifact:complete",
		workercontracts.OutputContainerMP4,
		1,
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := artifact.File().Write([]byte("complete")); err != nil {
		t.Fatal(err)
	}
	status, completed, err := rootSet.InspectStaged(
		"downloads",
		"artifact:complete",
		workercontracts.OutputContainerMP4,
	)
	if err != nil || status != StagedPartial || completed != nil {
		t.Fatalf("before retain = %v, %#v, %v", status, completed, err)
	}
	if err := artifact.Retain(); err != nil {
		t.Fatal(err)
	}
	status, completed, err = rootSet.InspectStaged(
		"downloads",
		"artifact:complete",
		workercontracts.OutputContainerMP4,
	)
	if err != nil || status != StagedComplete || completed == nil {
		t.Fatalf("after retain = %v, %#v, %v", status, completed, err)
	}
	if err := completed.Close(); err != nil {
		t.Fatal(err)
	}
}

func abandonStagedArtifact(t *testing.T, artifact StagedArtifact) {
	t.Helper()
	staged, ok := artifact.(*stagedArtifact)
	if !ok {
		t.Fatalf("unexpected staged artifact %T", artifact)
	}
	if err := staged.file.Close(); err != nil {
		t.Fatal(err)
	}
	if err := staged.directory.Close(); err != nil {
		t.Fatal(err)
	}
	staged.closed = true
}

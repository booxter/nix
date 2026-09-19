package mediafile

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
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

func TestPublishCompletedMovesArtifactToInputCommonParent(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	firstPath := filepath.Join(rootPath, "Movie", "CD1", "first.mkv")
	secondPath := filepath.Join(rootPath, "Movie", "CD2", "second.mkv")
	writeTestFile(t, firstPath, "first source")
	writeTestFile(t, secondPath, "second source")
	rootSet := testRootSet(t, rootPath)
	fingerprint := retainTestArtifact(
		t,
		rootSet,
		"artifact:publish",
		workercontracts.OutputContainerMKV,
		"joined media",
	)
	inputPaths := [][]string{
		{"Movie", "CD1", "first.mkv"},
		{"Movie", "CD2", "second.mkv"},
	}

	location, err := rootSet.PublishCompleted(
		"downloads",
		"artifact:publish",
		workercontracts.OutputContainerMKV,
		fingerprint,
		inputPaths,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(location) != 2 || location[0] != "Movie" ||
		!strings.HasPrefix(location[1], "radarr-repair-") ||
		!strings.HasSuffix(location[1], ".mkv") {
		t.Fatalf("published location = %#v", location)
	}
	publishedPath := filepath.Join(
		rootPath,
		filepath.Join(location...),
	)
	if data, readErr := os.ReadFile(publishedPath); readErr != nil || string(data) != "joined media" {
		t.Fatalf("published media = %q, error = %v", data, readErr)
	}
	publishedInfo, err := os.Stat(publishedPath)
	if err != nil {
		t.Fatal(err)
	}
	if publishedInfo.Mode().Perm() != 0o640 {
		t.Fatalf("published media mode = %o", publishedInfo.Mode().Perm())
	}
	if data, readErr := os.ReadFile(firstPath); readErr != nil || string(data) != "first source" {
		t.Fatalf("first source = %q, error = %v", data, readErr)
	}
	if data, readErr := os.ReadFile(secondPath); readErr != nil || string(data) != "second source" {
		t.Fatalf("second source = %q, error = %v", data, readErr)
	}
	status, completed, err := rootSet.InspectStaged(
		"downloads",
		"artifact:publish",
		workercontracts.OutputContainerMKV,
	)
	if err != nil || status != StagedMissing || completed != nil {
		t.Fatalf("staged artifact after publish = %v, %#v, %v", status, completed, err)
	}

	recovered, err := rootSet.PublishCompleted(
		"downloads",
		"artifact:publish",
		workercontracts.OutputContainerMKV,
		fingerprint,
		inputPaths,
	)
	if err != nil || !reflect.DeepEqual(recovered, location) {
		t.Fatalf("recovered location = %#v, error = %v", recovered, err)
	}
}

func TestPublishCompletedAtPlacesBluRayOutputBesideBDMV(t *testing.T) {
	t.Parallel()
	rootPath := t.TempDir()
	if err := os.Mkdir(filepath.Join(rootPath, "Movie"), 0o700); err != nil {
		t.Fatal(err)
	}
	rootSet := testRootSet(t, rootPath)
	fingerprint := retainTestArtifact(
		t, rootSet, "artifact:bluray", workercontracts.OutputContainerMKV, "remuxed media",
	)
	location, err := rootSet.PublishCompletedAt(
		"downloads", "artifact:bluray", workercontracts.OutputContainerMKV,
		fingerprint, []string{"Movie"},
	)
	if err != nil || len(location) != 2 || location[0] != "Movie" {
		t.Fatalf("published Blu-ray location = %#v, error = %v", location, err)
	}
	data, err := os.ReadFile(filepath.Join(rootPath, filepath.Join(location...)))
	if err != nil || string(data) != "remuxed media" {
		t.Fatalf("published Blu-ray = %q, error = %v", data, err)
	}
	recovered, err := rootSet.PublishCompletedAt(
		"downloads", "artifact:bluray", workercontracts.OutputContainerMKV,
		fingerprint, []string{"Movie"},
	)
	if err != nil || !reflect.DeepEqual(recovered, location) {
		t.Fatalf("recovered Blu-ray location = %#v, error = %v", recovered, err)
	}
	if _, err := rootSet.PublishCompletedAt(
		"downloads", "artifact:bluray", workercontracts.OutputContainerMKV,
		fingerprint, []string{".radarr-repair", "staged"},
	); err == nil {
		t.Fatal("accepted private worker directory as a publish destination")
	}
}

func TestPublishCompletedPreservesAVIExtension(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	if err := os.Mkdir(filepath.Join(rootPath, "Movie"), 0o700); err != nil {
		t.Fatal(err)
	}
	rootSet := testRootSet(t, rootPath)
	fingerprint := retainTestArtifact(
		t,
		rootSet,
		"artifact:avi",
		workercontracts.OutputContainerAVI,
		"joined media",
	)
	location, err := rootSet.PublishCompleted(
		"downloads",
		"artifact:avi",
		workercontracts.OutputContainerAVI,
		fingerprint,
		[][]string{{"Movie", "first.avi"}, {"Movie", "second.avi"}},
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(location) != 2 || !strings.HasSuffix(location[1], ".avi") {
		t.Fatalf("published location = %#v", location)
	}
}

func TestPublishCompletedDoesNotReplaceExistingDestination(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	if err := os.Mkdir(filepath.Join(rootPath, "Movie"), 0o700); err != nil {
		t.Fatal(err)
	}
	rootSet := testRootSet(t, rootPath)
	inputPaths := [][]string{{"Movie", "first.mkv"}, {"Movie", "second.mkv"}}
	firstFingerprint := retainTestArtifact(
		t,
		rootSet,
		"artifact:same",
		workercontracts.OutputContainerMP4,
		"first output",
	)
	location, err := rootSet.PublishCompleted(
		"downloads",
		"artifact:same",
		workercontracts.OutputContainerMP4,
		firstFingerprint,
		inputPaths,
	)
	if err != nil {
		t.Fatal(err)
	}

	secondFingerprint := retainTestArtifact(
		t,
		rootSet,
		"artifact:same",
		workercontracts.OutputContainerMP4,
		"second output",
	)
	_, err = rootSet.PublishCompleted(
		"downloads",
		"artifact:same",
		workercontracts.OutputContainerMP4,
		secondFingerprint,
		inputPaths,
	)
	assertFailureKind(t, err, FailureDestinationExists)
	publishedPath := filepath.Join(rootPath, filepath.Join(location...))
	if data, readErr := os.ReadFile(publishedPath); readErr != nil || string(data) != "first output" {
		t.Fatalf("published media = %q, error = %v", data, readErr)
	}
	status, completed, inspectErr := rootSet.InspectStaged(
		"downloads",
		"artifact:same",
		workercontracts.OutputContainerMP4,
	)
	if inspectErr != nil || status != StagedComplete || completed == nil {
		t.Fatalf("staged artifact = %v, %#v, %v", status, completed, inspectErr)
	}
	if closeErr := completed.Close(); closeErr != nil {
		t.Fatal(closeErr)
	}
}

func TestPublishCompletedRequiresExpectedFingerprint(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	if err := os.Mkdir(filepath.Join(rootPath, "Movie"), 0o700); err != nil {
		t.Fatal(err)
	}
	rootSet := testRootSet(t, rootPath)
	retainTestArtifact(
		t,
		rootSet,
		"artifact:fingerprint",
		workercontracts.OutputContainerMKV,
		"joined media",
	)
	_, err := rootSet.PublishCompleted(
		"downloads",
		"artifact:fingerprint",
		workercontracts.OutputContainerMKV,
		"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
		[][]string{{"Movie", "first.mkv"}, {"Movie", "second.mkv"}},
	)
	assertFailureKind(t, err, FailureFingerprintMismatch)
	status, completed, inspectErr := rootSet.InspectStaged(
		"downloads",
		"artifact:fingerprint",
		workercontracts.OutputContainerMKV,
	)
	if inspectErr != nil || status != StagedComplete || completed == nil {
		t.Fatalf("staged artifact = %v, %#v, %v", status, completed, inspectErr)
	}
	if closeErr := completed.Close(); closeErr != nil {
		t.Fatal(closeErr)
	}
}

func TestPublishCompletedRejectsUnsafeDestination(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(rootPath, "linked")); err != nil {
		t.Fatal(err)
	}
	rootSet := testRootSet(t, rootPath)
	fingerprint := retainTestArtifact(
		t,
		rootSet,
		"artifact:unsafe",
		workercontracts.OutputContainerMKV,
		"joined media",
	)
	for _, inputPaths := range [][][]string{
		{{"linked", "first.mkv"}, {"linked", "second.mkv"}},
		{{"..", "first.mkv"}, {"..", "second.mkv"}},
		{{workerDirectoryName, "first.mkv"}, {workerDirectoryName, "second.mkv"}},
	} {
		if _, err := rootSet.PublishCompleted(
			"downloads",
			"artifact:unsafe",
			workercontracts.OutputContainerMKV,
			fingerprint,
			inputPaths,
		); err == nil {
			t.Fatalf("unsafe input paths %#v were accepted", inputPaths)
		}
	}
	entries, err := os.ReadDir(outside)
	if err != nil || len(entries) != 0 {
		t.Fatalf("outside directory entries = %d, error = %v", len(entries), err)
	}
}

func TestPublishCompletedUsesRootForUnrelatedInputParents(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	if err := os.Mkdir(filepath.Join(rootPath, "first"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(rootPath, "second"), 0o700); err != nil {
		t.Fatal(err)
	}
	rootSet := testRootSet(t, rootPath)
	fingerprint := retainTestArtifact(
		t,
		rootSet,
		"artifact:root",
		workercontracts.OutputContainerMKV,
		"joined media",
	)
	location, err := rootSet.PublishCompleted(
		"downloads",
		"artifact:root",
		workercontracts.OutputContainerMKV,
		fingerprint,
		[][]string{{"first", "one.mkv"}, {"second", "two.mkv"}},
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(location) != 1 {
		t.Fatalf("published location = %#v", location)
	}
}

func retainTestArtifact(
	t *testing.T,
	rootSet *RootSet,
	artifactID string,
	container workercontracts.OutputContainer,
	contents string,
) string {
	t.Helper()
	artifact, err := rootSet.CreateStaged("downloads", artifactID, container, 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := artifact.File().Write([]byte(contents)); err != nil {
		t.Fatal(err)
	}
	fingerprint, _, err := artifact.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if err := artifact.Retain(); err != nil {
		t.Fatal(err)
	}
	return fingerprint
}

func writeTestFile(t *testing.T, path string, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
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

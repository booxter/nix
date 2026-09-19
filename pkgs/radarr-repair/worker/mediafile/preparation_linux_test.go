package mediafile

import (
	"testing"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

func TestPrepareStageClearsInterruptedArtifact(t *testing.T) {
	t.Parallel()

	rootSet := testRootSet(t, t.TempDir())
	artifact, err := rootSet.CreateStaged("downloads", "artifact:interrupted", workercontracts.OutputContainerMKV, 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := artifact.File().Write([]byte("partial")); err != nil {
		t.Fatal(err)
	}
	abandonStagedArtifact(t, artifact)

	completed, err := PrepareStage(rootSet, "downloads", "artifact:interrupted", workercontracts.OutputContainerMKV)
	if err != nil || completed != nil {
		t.Fatalf("prepare interrupted stage = %#v, %v", completed, err)
	}
	replacement, err := rootSet.CreateStaged("downloads", "artifact:interrupted", workercontracts.OutputContainerMKV, 1)
	if err != nil {
		t.Fatalf("create replacement stage: %v", err)
	}
	t.Cleanup(func() { _ = replacement.Discard() })
}

func TestPrepareStageRecoversCompletedArtifact(t *testing.T) {
	t.Parallel()

	rootSet := testRootSet(t, t.TempDir())
	artifact, err := rootSet.CreateStaged("downloads", "artifact:complete", workercontracts.OutputContainerMKV, 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := artifact.File().Write([]byte("complete")); err != nil {
		t.Fatal(err)
	}
	if err := artifact.Retain(); err != nil {
		t.Fatal(err)
	}

	completed, err := PrepareStage(rootSet, "downloads", "artifact:complete", workercontracts.OutputContainerMKV)
	if err != nil || completed == nil {
		t.Fatalf("prepare completed stage = %#v, %v", completed, err)
	}
	t.Cleanup(func() { _ = completed.Close() })
	_, size, err := completed.Snapshot()
	if err != nil || size != int64(len("complete")) {
		t.Fatalf("completed stage size = %d, %v", size, err)
	}
}

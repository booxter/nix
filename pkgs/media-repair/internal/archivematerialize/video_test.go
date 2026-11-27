package archivematerialize

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

type fakeWorker struct {
	root      string
	rarResult materialize.Success
}

func (worker *fakeWorker) MaterializeTarVideo(
	context.Context,
	string,
	fileidentity.Snapshot,
	string,
) (materialize.Success, error) {
	return materialize.Success{}, errors.New("fixture has no TAR archive")
}

func (worker *fakeWorker) MaterializeRARVideo(
	context.Context,
	string,
	fileidentity.Snapshot,
	string,
) (materialize.Success, error) {
	return worker.rarResult, nil
}

func (worker *fakeWorker) ResolvePublishedPath(_ string, components []string) (string, error) {
	return filepath.Join(append([]string{worker.root}, components...)...), nil
}

func TestMaterializeVideoArchive(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	workspace := []string{".media-repair", "workspaces", "radarr:test"}
	artifactComponents := append(append([]string(nil), workspace...), "Movie", "movie.mkv")
	artifactPath := filepath.Join(append([]string{root}, artifactComponents...)...)
	if err := os.MkdirAll(filepath.Dir(artifactPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(artifactPath, []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	worker := &fakeWorker{root: root, rarResult: materialize.Success{
		Operation: materialize.OperationMaterializeRARVideo,
		RootID:    "downloads", WorkspaceComponents: workspace,
		Artifacts: []materialize.Artifact{{
			ArtifactID: "artifact:movie", PathComponents: artifactComponents,
			RelativePath: "Movie/movie.mkv", SizeBytes: 5,
			Evidence: workercontracts.Evidence{},
		}},
	}}
	instance, err := New(worker)
	if err != nil {
		t.Fatal(err)
	}
	inventory := controller.FileInventory{
		Files: []controller.InventoryFile{{
			ID: "archive", PathComponents: []string{"release.rar"},
			Fingerprint: fileidentity.Snapshot{Device: 1, Inode: 2, SizeBytes: 100, MTimeNS: 3},
		}},
		Paths: []controller.FilePathMapping{{FileID: "archive", AbsolutePath: "/downloads/release.rar"}},
	}

	source, found, err := instance.MaterializeVideo(context.Background(), 71, inventory)
	if err != nil {
		t.Fatal(err)
	}
	if !found || source.Root != filepath.Join(root, filepath.Join(workspace...)) {
		t.Fatalf("expected extracted workspace, got %q (found = %v)", source.Root, found)
	}
	if len(source.Inventory.Files) != 1 || len(source.ExistingProbes) != 1 {
		t.Fatalf("expected one extracted file with a probe, got %#v", source)
	}
	file := source.Inventory.Files[0]
	if filepath.Join(file.PathComponents...) != "Movie/movie.mkv" || file.DownloadFile == nil ||
		source.ExistingProbes[0].FileID != file.ID {
		t.Fatalf("expected a probe for the extracted movie, got %#v", source)
	}
}

func TestMaterializeVideoKeepsDirectMedia(t *testing.T) {
	t.Parallel()
	worker := &fakeWorker{}
	instance, err := New(worker)
	if err != nil {
		t.Fatal(err)
	}
	inventory := controller.FileInventory{Files: []controller.InventoryFile{{
		ID: "movie", PathComponents: []string{"movie.mkv"},
		Fingerprint: fileidentity.Snapshot{SizeBytes: 100},
		DownloadFile: &controller.DownloadFileReference{
			LengthBytes: 100, BytesCompleted: 100, Selected: true,
		},
	}}}
	if _, found, err := instance.MaterializeVideo(context.Background(), 71, inventory); err != nil || found {
		t.Fatalf("found = %v, error = %v", found, err)
	}
}

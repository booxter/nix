package lidarrrepair

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

func TestInspectAlbumAfterDownloadDisappears(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	client := evidenceClient(root)
	collector := NewEvidenceCollector(client, &fakeWorker{root: root})
	queue := evidenceQueue(t.TempDir())
	archive := filepath.Join(queue.OutputPath, "album.tar")
	if err := os.WriteFile(archive, []byte("archive"), 0o600); err != nil {
		t.Fatal(err)
	}
	// Put the file reported by the fake worker on disk so a later inspection
	// can verify its contents after the original download is gone.
	path := client.imports[0].Path
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(testAudio), 0o640); err != nil {
		t.Fatal(err)
	}

	fresh := requireAlbumEvidence(t, collector.Inspect(t.Context(), queue, nil))
	if len(fresh.Case.Capabilities) != 1 {
		t.Fatalf("expected the missing track to be offered for import, got %+v", fresh.Case.Capabilities)
	}
	data, err := lidarrcontracts.EncodeCase(fresh.Case)
	if err != nil {
		t.Fatal(err)
	}
	record := Record{
		QueueID: queue.ID, Case: data, Bindings: fresh.Bindings,
		WorkspaceRoot: fresh.WorkspaceRoot, SourcePath: fresh.SourcePath,
		SourceKind: fresh.SourceKind, SourceFingerprint: fresh.SourceFingerprint,
	}

	if err := os.RemoveAll(queue.OutputPath); err != nil {
		t.Fatal(err)
	}
	client.trackInLibrary = true
	client.imports[0].IndexerFlags = 7
	recovered := requireAlbumEvidence(t, collector.Inspect(t.Context(), queue, &record))
	if !recovered.Recovered || recovered.SourceFingerprint != fresh.SourceFingerprint ||
		recovered.WorkspaceRoot != fresh.WorkspaceRoot {
		t.Fatal("inspection lost the identity of the saved workspace")
	}
	if len(recovered.Case.Capabilities) != 0 {
		t.Fatalf("offered to import a track already in the library: %+v", recovered.Case.Capabilities)
	}
	if len(recovered.Bindings) != 1 || recovered.Bindings[0].IndexerFlags != 7 {
		t.Fatalf("expected Lidarr's latest import settings, got %+v", recovered.Bindings)
	}

	// Keep the size unchanged so only checking the contents catches the edit.
	if err := os.WriteFile(path, []byte(strings.ToUpper(testAudio)), 0o640); err != nil {
		t.Fatal(err)
	}
	result := collector.Inspect(t.Context(), queue, &record)
	if result.Case != nil || result.Err == nil || !strings.Contains(result.Err.Error(), "changed contents") {
		t.Fatalf("expected changed workspace contents to stop inspection, got %+v", result)
	}
}

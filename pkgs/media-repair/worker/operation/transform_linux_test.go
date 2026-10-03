package operation

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/ffprobe"
	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"github.com/booxter/nix-config/media-repair/internal/mediaoperation"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
)

func TestJoinPublishesValidatedOutputAndPreservesSources(t *testing.T) {
	worker, request := joinFixture(t)
	output, err := worker.Transform(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if output.Path == "" || output.Fingerprint == "" {
		t.Fatalf("missing published output: %+v", output)
	}
	if _, err := os.Stat(output.Path); err != nil {
		t.Fatalf("published file unavailable: %v", err)
	}
	assertSourcesUnchanged(t, request)
}

func TestRejectedJoinNeverPublishes(t *testing.T) {
	worker, request := joinFixture(t)
	request.Join.ExpectedDurationMS = 60_000
	if _, err := worker.Transform(context.Background(), request); err == nil {
		t.Fatal("accepted a joined file with the wrong duration")
	}

	// Only the two source files may remain outside the private staging folder.
	entries, err := os.ReadDir(worker.Roots["downloads"])
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if !entry.IsDir() && entry.Name() != "first.mkv" && entry.Name() != "second.mkv" {
			t.Fatalf("published rejected output: %s", entry.Name())
		}
	}
	assertSourcesUnchanged(t, request)
}

func TestChangedSourceDoesNotPublish(t *testing.T) {
	worker, request := joinFixture(t)
	first := request.Join.OrderedParts[0]
	if err := os.WriteFile(request.Paths[first.FileID], []byte("changed"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := worker.Transform(context.Background(), request); err == nil {
		t.Fatal("accepted a changed source")
	}
}

func joinFixture(t *testing.T) (Transformer, mediaoperation.Transform) {
	t.Helper()
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	ffprobePath, err := exec.LookPath("ffprobe")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	roots := map[string]string{"downloads": root}
	files, err := mediafile.NewRootSet(roots)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = files.Close() })
	prober, err := ffprobe.NewRunner(ffprobePath, 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}

	request := mediaoperation.Transform{
		JobID:   1,
		Attempt: 1,
		Paths:   make(map[controller.FileID]string),
		Join: &decisionpolicy.AuthorizedJoin{
			ExpectedDurationMS:  800,
			DurationToleranceMS: 100,
			OutputContainer:     controller.OutputContainer("mkv"),
		},
	}
	var probes []controller.ProbeEvidence
	for _, name := range []string{"first.mkv", "second.mkv"} {
		path := filepath.Join(root, name)
		command := exec.Command(ffmpeg,
			"-hide_banner", "-loglevel", "error", "-nostdin",
			"-f", "lavfi", "-i", "color=c=red:s=16x16:r=25:d=0.4",
			"-map", "0:v:0", "-c:v", "ffv1", path,
		)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("generate source: %v: %s", err, output)
		}

		fingerprint := snapshot(t, path)
		id := controller.FileID(name)
		request.Paths[id] = path
		request.Join.OrderedParts = append(request.Join.OrderedParts, decisionpolicy.AuthorizedJoinPart{
			FileID:      id,
			Fingerprint: fingerprint,
		})
		request.Join.SourceBytes += fingerprint.SizeBytes

		file, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		probe, probeErr := prober.ProbeFile(context.Background(), file)
		closeErr := file.Close()
		if probeErr != nil || closeErr != nil {
			t.Fatalf("probe source: %v; close: %v", probeErr, closeErr)
		}
		probes = append(probes, probe)
	}

	assessment := controller.AssessStreamCompatibility(probes)
	if assessment.Layout == nil {
		t.Fatal("generated sources are incompatible")
	}
	request.Join.ExpectedStreamLayout = *assessment.Layout
	return Transformer{
		Roots:   roots,
		Files:   files,
		Prober:  prober,
		FFmpeg:  ffmpeg,
		Timeout: 10 * time.Second,
	}, request
}

func snapshot(t *testing.T, path string) fileidentity.Snapshot {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	fingerprint, err := fileidentity.FromFileInfo(info)
	if err != nil {
		t.Fatal(err)
	}
	return fingerprint
}

func assertSourcesUnchanged(t *testing.T, request mediaoperation.Transform) {
	t.Helper()
	for _, part := range request.Join.OrderedParts {
		if current := snapshot(t, request.Paths[part.FileID]); current != part.Fingerprint {
			t.Fatalf("source %s changed", part.FileID)
		}
	}
}

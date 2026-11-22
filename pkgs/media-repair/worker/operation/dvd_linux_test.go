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
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/media-repair/internal/ffprobe"
	"github.com/booxter/nix-config/media-repair/internal/mediaoperation"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
)

func TestDVDPublishesOneMovieWithChaptersInSelectedOrder(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	release := filepath.Join(root, "Movie")
	if err := os.Mkdir(release, 0o755); err != nil {
		t.Fatal(err)
	}
	roots := map[string]string{"downloads": root}
	files, err := mediafile.NewRootSet(roots)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = files.Close() })
	tools := func(name string) string {
		t.Helper()
		path, err := exec.LookPath(name)
		if err != nil {
			t.Fatal(err)
		}
		return path
	}
	prober, err := ffprobe.NewRunner(tools("ffprobe"), 15*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	worker := Transformer{
		Roots: roots, Files: files, Prober: prober,
		FFmpeg: tools("ffmpeg"), LSDVD: tools("lsdvd"), Timeout: time.Minute,
	}
	paths := make(map[controller.FileID]string)
	first := dvdFixture(t, worker, release, "Disc 1", "2", paths)
	second := dvdFixture(t, worker, release, "Disc 2", "4", paths)
	request := mediaoperation.Transform{
		JobID: 1, Attempt: 1, Paths: paths,
		DVD: &decisionpolicy.AuthorizedDVDSelection{
			Titles:         []decisionpolicy.AuthorizedDVD{second, first},
			MovieRuntimeMS: second.ExpectedDurationMS + first.ExpectedDurationMS, RuntimeToleranceMS: 300,
		},
	}

	output, err := worker.Transform(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	chapters := output.Evidence.Chapters
	if filepath.Dir(output.Path) != release || len(chapters) != 2 || chapters[1].StartTimeMS == nil ||
		*chapters[1].StartTimeMS < 3_800 || *chapters[1].StartTimeMS > 4_200 {
		t.Fatalf("wrong output directory or playback order: %s, %+v", output.Path, chapters)
	}
	private, err := os.ReadDir(filepath.Join(root, ".media-repair", "staged"))
	if err != nil || len(private) != 0 {
		t.Fatalf("private intermediates remained: %v, %v", private, err)
	}

	request.Attempt++
	request.DVD.Titles = []decisionpolicy.AuthorizedDVD{first}
	request.DVD.MovieRuntimeMS = first.ExpectedDurationMS
	output, err = worker.Transform(ctx, request)
	if err != nil || filepath.Dir(output.Path) != filepath.Join(release, "Disc 1") || len(output.Evidence.Chapters) > 1 {
		t.Fatalf("single-title output: %+v, %v", output, err)
	}
	for _, title := range []decisionpolicy.AuthorizedDVD{first, second} {
		for _, source := range title.Sources {
			if current := snapshot(t, paths[source.FileID]); current != source.Fingerprint {
				t.Fatalf("changed DVD source %s", source.FileID)
			}
		}
	}
}

func dvdFixture(
	t *testing.T, worker Transformer, release, disc, duration string, paths map[controller.FileID]string,
) decisionpolicy.AuthorizedDVD {
	t.Helper()
	mpeg := filepath.Join(t.TempDir(), "title.mpg")
	directory := filepath.Join(release, disc)
	commands := []*exec.Cmd{
		exec.Command(worker.FFmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=720x576:r=25",
			"-f", "lavfi", "-i", "sine=sample_rate=48000", "-t", duration, "-target", "pal-dvd", mpeg),
		exec.Command("dvdauthor", "-o", directory, "-t", mpeg),
		exec.Command("dvdauthor", "-o", directory, "-T"),
	}
	for _, command := range commands {
		command.Env = append(os.Environ(), "VIDEO_FORMAT=PAL")
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("author DVD fixture: %v: %s", err, out)
		}
	}
	videoTS := filepath.Join(directory, "VIDEO_TS")
	navigation := filepath.Join(videoTS, "VIDEO_TS.IFO")
	identifier := dvdvideo.Runner{Executable: worker.LSDVD}
	titles, err := identifier.IdentifyDVD(context.Background(), dvdvideo.Target{NavigationPath: navigation})
	if err != nil || len(titles) != 1 {
		t.Fatalf("identify DVD fixture: %v, %v", titles, err)
	}
	title := titles[0]
	authorized := decisionpolicy.AuthorizedDVD{
		CaseID: "dvd-case", CapabilityID: disc, TitleNumber: title.Number,
		ExpectedDurationMS: title.DurationMS, ExpectedChapters: title.Chapters, ExpectedTracks: title.Tracks,
	}
	entries, err := os.ReadDir(videoTS)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if !dvdvideo.ValidFileName(entry.Name()) {
			continue
		}
		path := filepath.Join(videoTS, entry.Name())
		id := controller.FileID(disc + "/" + entry.Name())
		paths[id] = path
		source := decisionpolicy.AuthorizedRemuxFile{FileID: id, Fingerprint: snapshot(t, path)}
		authorized.Sources = append(authorized.Sources, source)
		if path == navigation {
			authorized.Navigation = source
		}
	}
	return authorized
}

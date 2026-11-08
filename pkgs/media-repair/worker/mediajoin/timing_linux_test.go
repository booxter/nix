package mediajoin

import (
	"context"
	"crypto/sha256"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/ffprobe"
	"github.com/booxter/nix-config/media-repair/internal/joinverification"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

func TestSmallAverageRateDifferencePreservesPacketTiming(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	directory := t.TempDir()
	var parts []*os.File
	var probes []controller.ProbeEvidence
	var timelines []ffprobe.Timeline
	prober, err := ffprobe.NewRunner(toolPath(t, "ffprobe"), time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	for index := range 2 {
		path := filepath.Join(directory, strconv.Itoa(index)+".mp4")
		// One part has a one-frame gap halfway through. Both retain a nominal
		// 30 fps rate, while their measured average rates differ by about 0.06%.
		filter := "setpts='PTS+" + strconv.Itoa(index) + "*gte(N,900)/(30*TB)'"
		command := exec.Command(toolPath(t, "ffmpeg"),
			"-v", "error", "-f", "lavfi", "-i", "testsrc2=s=32x32:r=30:d=60",
			"-vf", filter, "-fps_mode", "passthrough", "-c:v", "libx264",
			"-video_track_timescale", "90000", path,
		)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("create average-rate fixture: %v: %s", err, output)
		}
		file := openTestFile(t, path, os.O_RDONLY)
		parts = append(parts, file)
		probe, err := prober.ProbeFile(ctx, file)
		if err != nil {
			t.Fatal(err)
		}
		probes = append(probes, probe)
		timeline, err := prober.Timeline(ctx, file)
		if err != nil {
			t.Fatal(err)
		}
		timelines = append(timelines, timeline)
	}
	if reflect.DeepEqual(probes[0].Streams[0].AverageRate, probes[1].Streams[0].AverageRate) {
		t.Fatal("fixture did not produce different average frame rates")
	}
	if assessment := controller.AssessStreamCompatibility(probes); assessment.Compatibility != controller.StreamsCompatible {
		t.Fatalf("average-rate fixture rejected: %+v", assessment)
	}

	output := openTestFile(t, filepath.Join(directory, "joined.mp4"), os.O_CREATE|os.O_EXCL|os.O_RDWR)
	if _, err := testRunner(t, time.Minute).Join(ctx, parts, output, workercontracts.OutputContainerMP4); err != nil {
		t.Fatal(err)
	}
	joined, err := prober.Timeline(ctx, output)
	if err != nil {
		t.Fatal(err)
	}
	if err := joinverification.ValidateTimeline(timelines, joined); err != nil {
		t.Fatalf("joined scenes lost packet timing: %v", err)
	}
}

func TestMixedTimeBasesPreserveEveryScene(t *testing.T) {
	ctx := context.Background()
	directory := t.TempDir()
	var parts []*os.File
	var digests [][sha256.Size]byte
	var timelines []ffprobe.Timeline
	prober, err := ffprobe.NewRunner(toolPath(t, "ffprobe"), time.Minute)
	if err != nil {
		t.Fatal(err)
	}

	for index, timescale := range []int{12800, 25, 12800} {
		path := filepath.Join(directory, strconv.Itoa(index)+".mp4")
		command := exec.Command(toolPath(t, "ffmpeg"),
			"-v", "error", "-f", "lavfi", "-i", "testsrc2=s=32x32:r=25:d=2",
			"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:d=2",
			"-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-bf", "2",
			"-c:a", "aac", "-video_track_timescale", strconv.Itoa(timescale), path,
		)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("create mixed-time-base fixture: %v: %s", err, output)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		digests = append(digests, sha256.Sum256(data))
		file := openTestFile(t, path, os.O_RDONLY)
		parts = append(parts, file)
		timeline, err := prober.Timeline(ctx, file)
		if err != nil {
			t.Fatal(err)
		}
		timelines = append(timelines, timeline)
	}

	// A mixed-time-base middle scene can collapse while later scenes restore
	// a plausible total duration.
	for _, part := range parts {
		if _, err := part.Seek(0, io.SeekStart); err != nil {
			t.Fatal(err)
		}
	}

	broken := openTestFile(t, filepath.Join(directory, "broken.mp4"), os.O_CREATE|os.O_EXCL|os.O_RDWR)
	command := exec.Command(toolPath(t, "ffmpeg"),
		"-v", "error", "-f", "concat", "-safe", "0", "-protocol_whitelist", "fd,pipe",
		"-i", "pipe:0", "-map", "0", "-c", "copy", "-f", "mp4", "-fd", "6", "fd:",
	)
	command.Stdin = strings.NewReader(concatManifest(len(parts)))
	command.ExtraFiles = append(append([]*os.File(nil), parts...), broken)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("reproduce corrupt join: %v: %s", err, output)
	}
	badTimeline, err := prober.Timeline(ctx, broken)
	if err != nil {
		t.Fatal(err)
	}
	if err := joinverification.ValidateTimeline(timelines, badTimeline); err == nil {
		t.Fatal("historical corrupt join passed timing validation")
	}

	output := openTestFile(t, filepath.Join(directory, "repaired.mp4"), os.O_CREATE|os.O_EXCL|os.O_RDWR)
	if _, err := testRunner(t, time.Minute).Join(ctx, parts, output, workercontracts.OutputContainerMP4); err != nil {
		t.Fatal(err)
	}
	for index, part := range parts {
		data, err := os.ReadFile(part.Name())
		if err != nil || sha256.Sum256(data) != digests[index] {
			t.Fatalf("source part %d changed: %v", index+1, err)
		}
	}
}

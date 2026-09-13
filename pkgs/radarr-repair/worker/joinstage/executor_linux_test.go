package joinstage

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/ffprobe"
	"github.com/booxter/nix-config/radarr-repair/internal/fileidentity"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/joinstate"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
	"github.com/booxter/nix-config/radarr-repair/worker/mediajoin"
	"golang.org/x/sys/unix"
)

func TestExecutorStagesRealMultipartMedia(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	firstPath := filepath.Join(rootPath, "first.mkv")
	secondPath := filepath.Join(rootPath, "second.mkv")
	makeMediaPart(t, firstPath, "red")
	makeMediaPart(t, secondPath, "blue")
	execution := preparedExecution(t, rootPath, []string{"second.mkv", "first.mkv"})
	rootSet := newRootSet(t, rootPath)
	joiner, err := mediajoin.NewRunner(
		requiredEnvironment(t, "RADARR_REPAIR_TEST_FFMPEG"),
		10*time.Second,
	)
	if err != nil {
		t.Fatal(err)
	}
	prober, err := ffprobe.NewRunner(
		requiredEnvironment(t, "RADARR_REPAIR_TEST_FFPROBE"),
		10*time.Second,
	)
	if err != nil {
		t.Fatal(err)
	}
	executor, err := NewExecutor(rootSet, rootSet, joiner, prober)
	if err != nil {
		t.Fatal(err)
	}

	result, err := executor.Stage(context.Background(), execution)
	if err != nil {
		t.Fatalf("stage media: %v, cause = %v", err, errors.Unwrap(err))
	}
	if result.Fingerprint == "" || result.SizeBytes <= 0 {
		t.Fatalf("staged result = %#v", result)
	}
	if result.Evidence.Format.DurationMS == nil ||
		*result.Evidence.Format.DurationMS < 700 ||
		*result.Evidence.Format.DurationMS > 1_000 {
		t.Fatalf("joined duration = %v", result.Evidence.Format.DurationMS)
	}
	if len(result.Evidence.Streams) != 1 ||
		result.Evidence.Streams[0].Kind == nil ||
		*result.Evidence.Streams[0].Kind != controller.ProbeStreamVideo {
		t.Fatalf("joined streams = %#v", result.Evidence.Streams)
	}
}

func TestExecutorPassesPartsInAuthorizedOrder(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	for name, data := range map[string]string{
		"first.mkv":  "first",
		"second.mkv": "second",
	} {
		if err := os.WriteFile(filepath.Join(rootPath, name), []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	execution := preparedExecution(t, rootPath, []string{"second.mkv", "first.mkv"})
	rootSet := newRootSet(t, rootPath)
	joiner := &concatenatingJoiner{}
	executor, err := NewExecutor(rootSet, rootSet, joiner, fixedProber{})
	if err != nil {
		t.Fatal(err)
	}

	result, err := executor.Stage(context.Background(), execution)
	if err != nil {
		t.Fatal(err)
	}
	if joiner.joined != "secondfirst" {
		t.Fatalf("joined contents = %q", joiner.joined)
	}
	if result.SizeBytes != int64(len("secondfirst")) {
		t.Fatalf("joined size = %d", result.SizeBytes)
	}
}

func TestExecutorRejectsChangedInputAndCleansArtifact(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	firstPath := filepath.Join(rootPath, "first.mkv")
	secondPath := filepath.Join(rootPath, "second.mkv")
	if err := os.WriteFile(firstPath, []byte("first"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(secondPath, []byte("second"), 0o600); err != nil {
		t.Fatal(err)
	}
	execution := preparedExecution(t, rootPath, []string{"first.mkv", "second.mkv"})
	rootSet := newRootSet(t, rootPath)
	changingJoiner := &concatenatingJoiner{afterJoin: func() {
		if err := os.WriteFile(firstPath, []byte("changed first"), 0o600); err != nil {
			t.Fatal(err)
		}
	}}
	executor, err := NewExecutor(rootSet, rootSet, changingJoiner, fixedProber{})
	if err != nil {
		t.Fatal(err)
	}

	_, err = executor.Stage(context.Background(), execution)
	assertFailureReason(t, err, workercontracts.StageJoinFingerprintMismatch)

	// A second creation of the same artifact succeeds only if the failed
	// attempt removed its private output.
	execution.Specification.Parts[0].ExpectedFingerprint = fingerprint(t, firstPath)
	info, err := os.Stat(firstPath)
	if err != nil {
		t.Fatal(err)
	}
	execution.Specification.ExpectedSourceBytes = info.Size() + fileSize(t, secondPath)
	retry, err := NewExecutor(rootSet, rootSet, &concatenatingJoiner{}, fixedProber{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := retry.Stage(context.Background(), execution); err != nil {
		t.Fatalf("retry after failed stage: %v", err)
	}
}

func TestExecutorReportsSourceSizeAndStorageFailures(t *testing.T) {
	t.Parallel()

	rootPath := t.TempDir()
	for _, name := range []string{"first.mkv", "second.mkv"} {
		if err := os.WriteFile(filepath.Join(rootPath, name), []byte(name), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	execution := preparedExecution(t, rootPath, []string{"first.mkv", "second.mkv"})
	rootSet := newRootSet(t, rootPath)
	execution.Specification.ExpectedSourceBytes++
	executor, err := NewExecutor(rootSet, rootSet, &concatenatingJoiner{}, fixedProber{})
	if err != nil {
		t.Fatal(err)
	}
	_, err = executor.Stage(context.Background(), execution)
	assertFailureReason(t, err, workercontracts.StageJoinSourceSizeMismatch)

	execution.Specification.ExpectedSourceBytes--
	executor, err = NewExecutor(
		rootSet,
		failingArtifacts{err: &mediafile.Failure{Kind: mediafile.FailureInsufficientSpace}},
		&concatenatingJoiner{},
		fixedProber{},
	)
	if err != nil {
		t.Fatal(err)
	}
	_, err = executor.Stage(context.Background(), execution)
	assertFailureReason(t, err, workercontracts.StageJoinInsufficientSpace)
}

func TestExecutorCleansArtifactAfterJoinOrProbeFailure(t *testing.T) {
	t.Parallel()

	for _, test := range []struct {
		name   string
		joiner mediajoin.Joiner
		prober MediaProber
		want   workercontracts.StageJoinFailureReason
	}{
		{
			name: "join failure",
			joiner: failingJoiner{err: &mediajoin.Failure{
				Kind: mediajoin.FailureExecution,
				Diagnostics: mediajoin.Diagnostics{
					Text: "bounded failure",
				},
			}},
			prober: fixedProber{},
			want:   workercontracts.StageJoinJoinError,
		},
		{
			name:   "probe failure",
			joiner: &concatenatingJoiner{},
			prober: failingProber{err: &ffprobe.Failure{Kind: ffprobe.FailureExecution}},
			want:   workercontracts.StageJoinProbeError,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			rootPath := t.TempDir()
			for _, name := range []string{"first.mkv", "second.mkv"} {
				if err := os.WriteFile(filepath.Join(rootPath, name), []byte(name), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			execution := preparedExecution(t, rootPath, []string{"first.mkv", "second.mkv"})
			rootSet := newRootSet(t, rootPath)
			executor, err := NewExecutor(rootSet, rootSet, test.joiner, test.prober)
			if err != nil {
				t.Fatal(err)
			}
			_, err = executor.Stage(context.Background(), execution)
			assertFailureReason(t, err, test.want)
			var failure *Failure
			if test.want == workercontracts.StageJoinJoinError &&
				(!errors.As(err, &failure) || failure.Diagnostics.Text != "bounded failure") {
				t.Fatalf("join diagnostics = %#v", failure)
			}

			retry, err := NewExecutor(rootSet, rootSet, &concatenatingJoiner{}, fixedProber{})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := retry.Stage(context.Background(), execution); err != nil {
				t.Fatalf("retry after failed stage: %v", err)
			}
		})
	}
}

type concatenatingJoiner struct {
	joined    string
	afterJoin func()
}

func (joiner *concatenatingJoiner) Join(
	_ context.Context,
	parts []*os.File,
	output *os.File,
	_ workercontracts.OutputContainer,
) (mediajoin.Result, error) {
	var joined []byte
	for _, part := range parts {
		if _, err := part.Seek(0, io.SeekStart); err != nil {
			return mediajoin.Result{}, err
		}
		data, err := io.ReadAll(part)
		if err != nil {
			return mediajoin.Result{}, err
		}
		joined = append(joined, data...)
	}
	if _, err := output.Write(joined); err != nil {
		return mediajoin.Result{}, err
	}
	joiner.joined = string(joined)
	if joiner.afterJoin != nil {
		joiner.afterJoin()
	}
	return mediajoin.Result{SizeBytes: int64(len(joined))}, nil
}

type failingJoiner struct {
	err error
}

func (joiner failingJoiner) Join(
	context.Context,
	[]*os.File,
	*os.File,
	workercontracts.OutputContainer,
) (mediajoin.Result, error) {
	return mediajoin.Result{}, joiner.err
}

type fixedProber struct{}

func (fixedProber) ProbeFile(
	context.Context,
	*os.File,
) (controller.ProbeEvidence, error) {
	return controller.ProbeEvidence{}, nil
}

type failingProber struct {
	err error
}

func (prober failingProber) ProbeFile(
	context.Context,
	*os.File,
) (controller.ProbeEvidence, error) {
	return controller.ProbeEvidence{}, prober.err
}

type failingArtifacts struct {
	err error
}

func (artifacts failingArtifacts) CreateStaged(
	string,
	string,
	workercontracts.OutputContainer,
	int64,
) (mediafile.StagedArtifact, error) {
	return nil, artifacts.err
}

func preparedExecution(
	t *testing.T,
	rootPath string,
	orderedNames []string,
) joinstate.Execution {
	t.Helper()
	parts := make([]joinstate.Part, len(orderedNames))
	var sourceBytes int64
	for index, name := range orderedNames {
		path := filepath.Join(rootPath, name)
		parts[index] = joinstate.Part{
			FileID:              "file:" + name,
			PathComponents:      []string{name},
			ExpectedFingerprint: fingerprint(t, path),
		}
		sourceBytes += fileSize(t, path)
	}
	return joinstate.Execution{
		ArtifactID: "artifact:test",
		State:      joinstate.Prepared,
		Specification: joinstate.Specification{
			ExecutionID:         "execution:test",
			CaseID:              "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			CapabilityID:        "capability:test",
			RootID:              "downloads",
			Parts:               parts,
			OutputContainer:     workercontracts.OutputContainerMKV,
			ExpectedSourceBytes: sourceBytes,
			ExpectedDurationMS:  800,
			DurationToleranceMS: 100,
			ExpectedStreamCount: 1,
		},
	}
}

func newRootSet(t *testing.T, rootPath string) *mediafile.RootSet {
	t.Helper()
	rootSet, err := mediafile.NewRootSet(map[string]string{"downloads": rootPath})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = rootSet.Close() })
	return rootSet
}

func fingerprint(t *testing.T, path string) string {
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

func fileSize(t *testing.T, path string) int64 {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Size()
}

func makeMediaPart(t *testing.T, path string, color string) {
	t.Helper()
	command := exec.Command(
		requiredEnvironment(t, "RADARR_REPAIR_TEST_FFMPEG"),
		"-hide_banner",
		"-loglevel", "error",
		"-nostdin",
		"-f", "lavfi",
		"-i", "color=c="+color+":s=16x16:r=25:d=0.4",
		"-map", "0:v:0",
		"-c:v", "ffv1",
		"-y", path,
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("make media part: %v: %s", err, output)
	}
}

func requiredEnvironment(t *testing.T, name string) string {
	t.Helper()
	value := os.Getenv(name)
	if value == "" {
		t.Fatalf("%s is not set", name)
	}
	return value
}

func assertFailureReason(
	t *testing.T,
	err error,
	want workercontracts.StageJoinFailureReason,
) {
	t.Helper()
	var failure *Failure
	if !errors.As(err, &failure) || failure.Reason != want {
		t.Fatalf("stage error = %v, want %q", err, want)
	}
}

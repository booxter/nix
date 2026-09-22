package workerprobe

import (
	"context"
	"errors"
	"os"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/ffprobe"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
)

func TestExecutorReturnsSuccessAndClosesMedia(t *testing.T) {
	t.Parallel()

	media := temporaryMedia(t)
	evidence := controller.ProbeEvidence{}
	executor := testExecutor(t, &fakeMediaFiles{media: media}, &fakeMediaProber{
		media:    media,
		evidence: evidence,
	})
	response := executor.Execute(context.Background(), testRequest())
	if response.Kind != workercontracts.ProbeResponseSucceeded || response.Success == nil {
		t.Fatalf("response = %#v", response)
	}
	if _, err := workercontracts.EncodeProbeResponse(response); err != nil {
		t.Fatalf("encode response: %v", err)
	}
	if _, err := media.Stat(); err == nil {
		t.Fatal("media file remains open")
	}
}

func TestExecutorMapsFileFailures(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		err  error
		want workercontracts.Reason
	}{
		{name: "unknown root", err: &mediafile.Failure{Kind: mediafile.FailureUnknownRoot}, want: workercontracts.UnknownRoot},
		{name: "invalid path", err: &mediafile.Failure{Kind: mediafile.FailureInvalidPath}, want: workercontracts.InvalidPath},
		{name: "unavailable", err: &mediafile.Failure{Kind: mediafile.FailureFileUnavailable}, want: workercontracts.FileUnavailable},
		{name: "not regular", err: &mediafile.Failure{Kind: mediafile.FailureNotRegularFile}, want: workercontracts.NotRegularFile},
		{name: "changed", err: &mediafile.Failure{Kind: mediafile.FailureFingerprintMismatch}, want: workercontracts.FingerprintMismatch},
		{name: "internal", err: &mediafile.Failure{Kind: mediafile.FailureInternal}, want: workercontracts.InternalError},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			executor := testExecutor(t, &fakeMediaFiles{openErr: test.err}, &fakeMediaProber{})
			assertFailureReason(t, executor.Execute(context.Background(), testRequest()), test.want)
		})
	}
}

func TestExecutorMapsProbeFailures(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		err  error
		want workercontracts.Reason
	}{
		{name: "timeout", err: &ffprobe.Failure{Kind: ffprobe.FailureTimeout}, want: workercontracts.Timeout},
		{name: "execution", err: &ffprobe.Failure{Kind: ffprobe.FailureExecution}, want: workercontracts.ProbeError},
		{name: "invalid output", err: &ffprobe.Failure{Kind: ffprobe.FailureInvalidOutput}, want: workercontracts.InvalidOutput},
		{name: "cancelled", err: context.Canceled, want: workercontracts.Timeout},
		{name: "unexpected", err: errors.New("unexpected"), want: workercontracts.InternalError},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			media := temporaryMedia(t)
			executor := testExecutor(t, &fakeMediaFiles{media: media}, &fakeMediaProber{
				media: media,
				err:   test.err,
			})
			assertFailureReason(t, executor.Execute(context.Background(), testRequest()), test.want)
		})
	}
}

func TestExecutorPrefersPostProbeFileFailure(t *testing.T) {
	t.Parallel()

	media := temporaryMedia(t)
	executor := testExecutor(t, &fakeMediaFiles{
		media:     media,
		verifyErr: &mediafile.Failure{Kind: mediafile.FailureFingerprintMismatch},
	}, &fakeMediaProber{
		media: media,
		err:   &ffprobe.Failure{Kind: ffprobe.FailureExecution},
	})
	assertFailureReason(
		t,
		executor.Execute(context.Background(), testRequest()),
		workercontracts.FingerprintMismatch,
	)
}

func TestExecutorHonorsCancelledContextBeforeOpening(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	files := &fakeMediaFiles{}
	executor := testExecutor(t, files, &fakeMediaProber{})
	assertFailureReason(t, executor.Execute(ctx, testRequest()), workercontracts.Timeout)
	if files.opened {
		t.Fatal("media file was opened")
	}
}

func TestNewExecutorRejectsMissingDependencies(t *testing.T) {
	t.Parallel()

	if _, err := NewExecutor(nil, &fakeMediaProber{}); err == nil {
		t.Fatal("missing media file access was accepted")
	}
	if _, err := NewExecutor(&fakeMediaFiles{}, nil); err == nil {
		t.Fatal("missing media prober was accepted")
	}
}

type fakeMediaFiles struct {
	media     *os.File
	openErr   error
	verifyErr error
	opened    bool
}

func (files *fakeMediaFiles) Open(
	rootID string,
	pathComponents []string,
	expectedFingerprint string,
) (*os.File, error) {
	files.opened = true
	request := testRequest()
	if rootID != request.RootID || expectedFingerprint != request.ExpectedFingerprint ||
		len(pathComponents) != 1 || pathComponents[0] != request.PathComponents[0] {
		return nil, errors.New("unexpected media identity")
	}
	return files.media, files.openErr
}

func (files *fakeMediaFiles) Verify(media *os.File, expectedFingerprint string) error {
	if media != files.media || expectedFingerprint != testRequest().ExpectedFingerprint {
		return errors.New("unexpected media identity")
	}
	return files.verifyErr
}

type fakeMediaProber struct {
	media    *os.File
	evidence controller.ProbeEvidence
	err      error
}

func (prober *fakeMediaProber) ProbeFile(
	_ context.Context,
	media *os.File,
) (controller.ProbeEvidence, error) {
	if media != prober.media {
		return controller.ProbeEvidence{}, errors.New("unexpected media file")
	}
	return prober.evidence, prober.err
}

func testExecutor(t *testing.T, files MediaFiles, prober MediaProber) *Executor {
	t.Helper()
	executor, err := NewExecutor(files, prober)
	if err != nil {
		t.Fatal(err)
	}
	return executor
}

func testRequest() workercontracts.ProbeRequestV1 {
	return workercontracts.ProbeRequestV1{
		ExpectedFingerprint: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		Operation:           workercontracts.ProbeV1,
		PathComponents:      []string{"movie.mkv"},
		RequestID:           "request:01",
		RootID:              "root:downloads",
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	}
}

func temporaryMedia(t *testing.T) *os.File {
	t.Helper()
	media, err := os.CreateTemp(t.TempDir(), "media-")
	if err != nil {
		t.Fatal(err)
	}
	return media
}

func assertFailureReason(
	t *testing.T,
	response workercontracts.ProbeResponseV1,
	want workercontracts.Reason,
) {
	t.Helper()
	if response.Kind != workercontracts.ProbeResponseFailed || response.Failure == nil ||
		response.Failure.Reason != want {
		t.Fatalf("response = %#v, want reason %q", response, want)
	}
	if _, err := workercontracts.EncodeProbeResponse(response); err != nil {
		t.Fatalf("encode response: %v", err)
	}
}

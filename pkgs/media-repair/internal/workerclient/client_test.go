package workerclient

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	workerprobe "github.com/booxter/nix-config/media-repair/worker/probe"
)

func TestClientProbesThroughWorker(t *testing.T) {
	t.Parallel()

	wantEvidence := completeEvidence()
	requests := make(chan workercontracts.ProbeRequestV1, 1)
	handler := http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		probeRequest, err := readProbeRequest(request)
		if err != nil {
			http.Error(writer, "invalid request", http.StatusBadRequest)
			return
		}
		requests <- probeRequest
		writeProbeResponse(writer, workerprobe.SuccessResponse(
			probeRequest.RequestID,
			wantEvidence,
		))
	})
	client := testClient(t, handler, map[string]string{
		"root:downloads": "/downloads",
		"root:movies":    "/downloads/Movies",
	}, time.Second)
	target := controller.MediaProbeTarget{
		AbsolutePath: "/downloads/Movies/Example/movie.mkv",
		Fingerprint: controller.FileFingerprint{
			Device: 7, Inode: 11, SizeBytes: 1_024, MTimeNS: 99,
		},
	}

	outcome, err := client.Probe(context.Background(), target)
	if err != nil {
		t.Fatal(err)
	}
	if outcome.Status != controller.MediaProbeSucceeded ||
		outcome.Evidence == nil || !reflect.DeepEqual(*outcome.Evidence, wantEvidence) {
		t.Fatalf("outcome = %#v, want evidence %#v", outcome, wantEvidence)
	}
	probeRequest := <-requests
	if probeRequest.RootID != "root:movies" ||
		!reflect.DeepEqual(probeRequest.PathComponents, []string{"Example", "movie.mkv"}) ||
		probeRequest.ExpectedFingerprint != target.Fingerprint.StrictFingerprint() ||
		probeRequest.RequestID != "request:1" {
		t.Fatalf("request = %#v", probeRequest)
	}
}

func TestClientRetainsTypedMediaProbeFailures(t *testing.T) {
	t.Parallel()

	tests := []struct {
		workerReason workercontracts.Reason
		wantReason   controller.MediaProbeReason
	}{
		{workercontracts.NotRegularFile, controller.MediaProbeNotRegularFile},
		{workercontracts.UnsupportedFormat, controller.MediaProbeUnsupportedFormat},
		{workercontracts.Timeout, controller.MediaProbeTimeout},
		{workercontracts.ProbeError, controller.MediaProbeError},
		{workercontracts.InvalidOutput, controller.MediaProbeInvalidOutput},
	}
	for _, test := range tests {
		t.Run(string(test.workerReason), func(t *testing.T) {
			t.Parallel()
			handler := http.HandlerFunc(func(
				writer http.ResponseWriter,
				request *http.Request,
			) {
				probeRequest, err := readProbeRequest(request)
				if err != nil {
					http.Error(writer, "invalid request", http.StatusBadRequest)
					return
				}
				writeProbeResponse(writer, workerprobe.FailureResponse(
					probeRequest.RequestID,
					test.workerReason,
				))
			})
			client := testClient(t, handler, testRoots(), time.Second)
			outcome, err := client.Probe(context.Background(), testTarget())
			if err != nil {
				t.Fatal(err)
			}
			if outcome.Status != controller.MediaProbeFailed ||
				outcome.Reason != test.wantReason || outcome.Evidence != nil {
				t.Fatalf("outcome = %#v", outcome)
			}
		})
	}
}

func TestClientReturnsTypedWorkerRejection(t *testing.T) {
	t.Parallel()

	handler := http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		probeRequest, err := readProbeRequest(request)
		if err != nil {
			http.Error(writer, "invalid request", http.StatusBadRequest)
			return
		}
		writeProbeResponse(writer, workerprobe.FailureResponse(
			probeRequest.RequestID,
			workercontracts.FingerprintMismatch,
		))
	})
	client := testClient(t, handler, testRoots(), time.Second)

	_, err := client.Probe(context.Background(), testTarget())
	assertFailure(t, err, FailureRejected, workercontracts.FingerprintMismatch)
}

func TestConvertEvidencePreservesEmptyCollections(t *testing.T) {
	t.Parallel()

	evidence := EvidenceFromWorker(workercontracts.Evidence{
		Format: workercontracts.Format{
			Names: []string{},
			Tags:  []workercontracts.TagElement{},
		},
		Streams:  []workercontracts.StreamElement{},
		Programs: []workercontracts.ProgramElement{},
		Chapters: []workercontracts.ChapterElement{},
	})
	if evidence.Format.Names == nil || evidence.Format.Tags == nil ||
		evidence.Streams == nil || evidence.Programs == nil || evidence.Chapters == nil {
		t.Fatalf("empty collections became nil: %#v", evidence)
	}
}

func TestClientRejectsInvalidResponses(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		handler http.HandlerFunc
		kind    FailureKind
	}{
		{
			name: "malformed JSON",
			handler: func(writer http.ResponseWriter, _ *http.Request) {
				writer.Header().Set("Content-Type", "application/json")
				_, _ = writer.Write([]byte("{"))
			},
			kind: FailureInvalidResponse,
		},
		{
			name: "mismatched request ID",
			handler: func(writer http.ResponseWriter, _ *http.Request) {
				writeProbeResponse(writer, workerprobe.FailureResponse(
					"request:other",
					workercontracts.ProbeError,
				))
			},
			kind: FailureInvalidResponse,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			client := testClient(t, test.handler, testRoots(), time.Second)
			_, err := client.Probe(context.Background(), testTarget())
			assertFailure(t, err, test.kind, "")
		})
	}
}

func TestClientRejectsUnmappedAndInvalidTargets(t *testing.T) {
	t.Parallel()

	client := testClient(t, nil, testRoots(), time.Second)
	for _, target := range []controller.MediaProbeTarget{
		{AbsolutePath: "relative/movie.mkv"},
		{AbsolutePath: "/downloads"},
		{AbsolutePath: "/other/movie.mkv"},
	} {
		if _, err := client.Probe(context.Background(), target); err == nil {
			t.Fatalf("target %#v was accepted", target)
		}
	}
}

func TestClientResolvesPublishedPath(t *testing.T) {
	t.Parallel()

	client := testClient(t, nil, map[string]string{
		"root:downloads": "/downloads",
		"root:movies":    "/downloads/Movies",
	}, time.Second)
	path, err := client.ResolvePublishedPath(
		"root:movies",
		[]string{"Example", "radarr-repair-join.mkv"},
	)
	if err != nil || path != "/downloads/Movies/Example/radarr-repair-join.mkv" {
		t.Fatalf("path = %q, error = %v", path, err)
	}
}

func TestClientRejectsInvalidPublishedPaths(t *testing.T) {
	t.Parallel()

	client := testClient(t, nil, map[string]string{
		"root:downloads": "/downloads",
		"root:movies":    "/downloads/Movies",
	}, time.Second)
	tests := []struct {
		rootID     string
		components []string
	}{
		{rootID: "root:other", components: []string{"movie.mkv"}},
		{rootID: "root:downloads"},
		{rootID: "root:downloads", components: []string{"..", "movie.mkv"}},
		{rootID: "root:downloads", components: []string{"folder/movie.mkv"}},
		{
			rootID: "root:downloads",
			components: []string{
				"Movies",
				"movie.mkv",
			},
		},
	}
	for _, test := range tests {
		if path, err := client.ResolvePublishedPath(test.rootID, test.components); err == nil {
			t.Fatalf("published path %q was accepted as %q", test.components, path)
		}
	}
}

func TestNewRejectsInvalidConfiguration(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		roots   map[string]string
		timeout time.Duration
	}{
		{name: "no roots", timeout: time.Second},
		{
			name:  "invalid root ID",
			roots: map[string]string{"INVALID ROOT": "/downloads"}, timeout: time.Second,
		},
		{
			name:  "relative root",
			roots: map[string]string{"root:downloads": "downloads"}, timeout: time.Second,
		},
		{
			name: "duplicate root path",
			roots: map[string]string{
				"root:first": "/downloads", "root:second": "/downloads",
			},
			timeout: time.Second,
		},
		{
			name:  "zero timeout",
			roots: testRoots(), timeout: 0,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if _, err := newClient(test.roots, test.timeout, time.Minute); err == nil {
				t.Fatal("invalid configuration was accepted")
			}
		})
	}
	if _, err := newClient(testRoots(), time.Second, 0); err == nil {
		t.Fatal("zero stage timeout was accepted")
	}
}

func testClient(
	t *testing.T,
	handler http.Handler,
	roots map[string]string,
	timeout time.Duration,
) *Client {
	t.Helper()
	client, err := newClient(roots, timeout, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	client.runner = handlerRunner{handler}
	return client
}

func testRoots() map[string]string {
	return map[string]string{"root:downloads": "/downloads"}
}

func testTarget() controller.MediaProbeTarget {
	return controller.MediaProbeTarget{
		AbsolutePath: "/downloads/movie.mkv",
		Fingerprint: controller.FileFingerprint{
			Device: 1, Inode: 2, SizeBytes: 3, MTimeNS: 4,
		},
	}
}

type handlerRunner struct{ handler http.Handler }

func (runner handlerRunner) Run(ctx context.Context, operation string, payload []byte, _ int) ([]byte, error) {
	request := httptest.NewRequestWithContext(ctx, http.MethodPost, operation, strings.NewReader(string(payload)))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	runner.handler.ServeHTTP(response, request)
	return response.Body.Bytes(), nil
}

func readProbeRequest(request *http.Request) (workercontracts.ProbeRequestV1, error) {
	if request.Method != http.MethodPost || request.URL.Path != "/v1/probe" ||
		request.Header.Get("Content-Type") != "application/json" {
		return workercontracts.ProbeRequestV1{}, fmt.Errorf("unexpected request")
	}
	data, err := io.ReadAll(request.Body)
	if err != nil {
		return workercontracts.ProbeRequestV1{}, err
	}
	return workercontracts.DecodeProbeRequest(data)
}

func writeProbeResponse(writer http.ResponseWriter, response workercontracts.ProbeResponseV1) {
	data, err := workercontracts.EncodeProbeResponse(response)
	if err != nil {
		writer.WriteHeader(http.StatusInternalServerError)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	_, _ = writer.Write(data)
}

func assertFailure(
	t *testing.T,
	err error,
	wantKind FailureKind,
	wantReason workercontracts.Reason,
) {
	t.Helper()
	var failure *Failure
	if !errors.As(err, &failure) || failure.Kind != wantKind || failure.Reason != wantReason {
		t.Fatalf("error = %#v, want kind %d and reason %q", err, wantKind, wantReason)
	}
}

func completeEvidence() controller.ProbeEvidence {
	longName := "Matroska"
	streamCount := int64(2)
	programCount := int64(1)
	zero := int64(0)
	duration := int64(1_000)
	size := int64(2_048)
	bitRate := int64(16_384)
	probeScore := int64(100)
	kind := controller.ProbeStreamVideo
	codecName := "h264"
	codecLongName := "H.264"
	profile := "High"
	codecTag := "avc1"
	width := int64(1920)
	height := int64(1080)
	pixelFormat := "yuv420p"
	sampleFormat := "fltp"
	sampleRate := int64(48_000)
	channels := int64(2)
	channelLayout := "stereo"
	durationTicks := int64(90_000)
	frameCount := int64(24)
	trueValue := true
	falseValue := false
	programNumber := int64(7)
	pmtPID := int64(100)
	pcrPID := int64(101)
	chapterID := int64(9)
	chapterEnd := int64(1_000)
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names: []string{"matroska", "webm"}, LongName: &longName,
			StreamCount: &streamCount, ProgramCount: &programCount,
			StartTimeMS: &zero, DurationMS: &duration, SizeBytes: &size,
			BitRateBPS: &bitRate, ProbeScore: &probeScore,
			Tags: []controller.ProbeTag{{Name: "encoder", Value: "fixture"}},
		},
		Streams: []controller.ProbeStream{{
			Index: 0, Kind: &kind, CodecName: &codecName, CodecLongName: &codecLongName,
			Profile: &profile, CodecTag: &codecTag, Width: &width, Height: &height,
			PixelFormat: &pixelFormat, SampleFormat: &sampleFormat,
			SampleRateHz: &sampleRate, Channels: &channels, ChannelLayout: &channelLayout,
			FrameRate:   &controller.Rational{Numerator: 24, Denominator: 1},
			AverageRate: &controller.Rational{Numerator: 24_000, Denominator: 1_001},
			TimeBase:    &controller.Rational{Numerator: 1, Denominator: 90_000},
			StartTicks:  &zero, StartTimeMS: &zero, DurationTicks: &durationTicks,
			DurationMS: &duration, BitRateBPS: &bitRate, FrameCount: &frameCount,
			Disposition: &controller.ProbeDisposition{
				Default: &trueValue, Forced: &falseValue,
				HearingImpaired: &falseValue, VisualImpaired: &falseValue,
			},
			Tags: []controller.ProbeTag{{Name: "language", Value: "eng"}},
		}},
		Programs: []controller.ProbeProgram{{
			ID: 3, Number: &programNumber, StreamCount: &streamCount,
			PMTPID: &pmtPID, PCRPID: &pcrPID, StreamIndexes: []int64{0, 1},
			Tags: []controller.ProbeTag{{Name: "service_name", Value: "movie"}},
		}},
		Chapters: []controller.ProbeChapter{{
			ID: chapterID, TimeBase: &controller.Rational{Numerator: 1, Denominator: 1_000},
			StartTicks: &zero, StartTimeMS: &zero, EndTicks: &chapterEnd,
			EndTimeMS: &chapterEnd,
			Tags:      []controller.ProbeTag{{Name: "title", Value: "Chapter"}},
		}},
	}
}

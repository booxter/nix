package workerclient

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	workerprobe "github.com/booxter/nix-config/radarr-repair/worker/probe"
)

func TestClientProbesThroughUnixSocket(t *testing.T) {
	t.Parallel()

	wantEvidence := completeEvidence()
	requests := make(chan workercontracts.ProbeRequestV1, 1)
	socketPath := serveUnix(t, http.HandlerFunc(func(
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
	}))
	client := testClient(t, socketPath, map[string]string{
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
		probeRequest.ExpectedFingerprint != target.Fingerprint.Fingerprint() ||
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
			socketPath := serveUnix(t, http.HandlerFunc(func(
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
			}))
			client := testClient(t, socketPath, testRoots(), time.Second)
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

	socketPath := serveUnix(t, http.HandlerFunc(func(
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
	}))
	client := testClient(t, socketPath, testRoots(), time.Second)

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
			name: "HTTP status",
			handler: func(writer http.ResponseWriter, _ *http.Request) {
				http.Error(writer, "do-not-expose-response", http.StatusServiceUnavailable)
			},
			kind: FailureHTTP,
		},
		{
			name: "wrong content type",
			handler: func(writer http.ResponseWriter, _ *http.Request) {
				writer.Header().Set("Content-Type", "text/plain")
				_, _ = writer.Write([]byte("{}"))
			},
			kind: FailureInvalidResponse,
		},
		{
			name: "malformed JSON",
			handler: func(writer http.ResponseWriter, _ *http.Request) {
				writer.Header().Set("Content-Type", "application/json")
				_, _ = writer.Write([]byte("{"))
			},
			kind: FailureInvalidResponse,
		},
		{
			name: "oversized body",
			handler: func(writer http.ResponseWriter, _ *http.Request) {
				writer.Header().Set("Content-Type", "application/json")
				_, _ = io.WriteString(
					writer,
					strings.Repeat("x", workercontracts.MaxProbeResponseBytes+1),
				)
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
			socketPath := serveUnix(t, test.handler)
			client := testClient(t, socketPath, testRoots(), time.Second)
			_, err := client.Probe(context.Background(), testTarget())
			assertFailure(t, err, test.kind, "")
			if strings.Contains(fmt.Sprint(err), "do-not-expose-response") {
				t.Fatalf("error exposes response body: %v", err)
			}
		})
	}
}

func TestClientClassifiesUnavailableWorkerAndTimeout(t *testing.T) {
	t.Parallel()

	t.Run("unavailable", func(t *testing.T) {
		t.Parallel()
		client := testClient(
			t,
			filepath.Join(t.TempDir(), "missing.sock"),
			testRoots(),
			time.Second,
		)
		_, err := client.Probe(context.Background(), testTarget())
		assertFailure(t, err, FailureUnavailable, "")
		if strings.Contains(err.Error(), ".sock") {
			t.Fatalf("error exposes socket path: %v", err)
		}
	})

	t.Run("timeout", func(t *testing.T) {
		t.Parallel()
		socketPath := serveUnix(t, http.HandlerFunc(func(
			_ http.ResponseWriter,
			request *http.Request,
		) {
			<-request.Context().Done()
		}))
		client := testClient(t, socketPath, testRoots(), 20*time.Millisecond)
		_, err := client.Probe(context.Background(), testTarget())
		assertFailure(t, err, FailureTimeout, "")
	})
}

func TestClientHonorsCallerCancellation(t *testing.T) {
	t.Parallel()

	client := testClient(
		t,
		filepath.Join(t.TempDir(), "missing.sock"),
		testRoots(),
		time.Second,
	)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := client.Probe(ctx, testTarget())
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v", err)
	}
}

func TestClientRejectsUnmappedAndInvalidTargets(t *testing.T) {
	t.Parallel()

	client := testClient(t, "/run/worker.sock", testRoots(), time.Second)
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

	client := testClient(t, "/run/worker.sock", map[string]string{
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

	client := testClient(t, "/run/worker.sock", map[string]string{
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
		socket  string
		roots   map[string]string
		timeout time.Duration
	}{
		{name: "relative socket", socket: "worker.sock", roots: testRoots(), timeout: time.Second},
		{name: "no roots", socket: "/run/worker.sock", timeout: time.Second},
		{
			name: "invalid root ID", socket: "/run/worker.sock",
			roots: map[string]string{"INVALID ROOT": "/downloads"}, timeout: time.Second,
		},
		{
			name: "relative root", socket: "/run/worker.sock",
			roots: map[string]string{"root:downloads": "downloads"}, timeout: time.Second,
		},
		{
			name: "duplicate root path", socket: "/run/worker.sock",
			roots: map[string]string{
				"root:first": "/downloads", "root:second": "/downloads",
			},
			timeout: time.Second,
		},
		{
			name: "zero timeout", socket: "/run/worker.sock",
			roots: testRoots(), timeout: 0,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if _, err := New(test.socket, test.roots, test.timeout); err == nil {
				t.Fatal("invalid configuration was accepted")
			}
		})
	}
}

func testClient(
	t *testing.T,
	socketPath string,
	roots map[string]string,
	timeout time.Duration,
) *Client {
	t.Helper()
	client, err := New(socketPath, roots, timeout)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
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

func serveUnix(t *testing.T, handler http.Handler) string {
	t.Helper()
	socketPath := filepath.Join(t.TempDir(), "worker.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: handler}
	done := make(chan error, 1)
	go func() {
		done <- server.Serve(listener)
	}()
	t.Cleanup(func() {
		if err := server.Close(); err != nil {
			t.Errorf("close server: %v", err)
		}
		if err := <-done; err != nil && !errors.Is(err, http.ErrServerClosed) {
			t.Errorf("serve worker test requests: %v", err)
		}
	})
	return socketPath
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

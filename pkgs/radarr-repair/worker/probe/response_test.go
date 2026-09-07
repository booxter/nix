package workerprobe

import (
	"reflect"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

func TestSuccessResponseConvertsCompleteEvidence(t *testing.T) {
	t.Parallel()

	evidence := completeEvidence()
	response := SuccessResponse("request:01", evidence)
	if response.Kind != workercontracts.ProbeResponseSucceeded || response.Success == nil ||
		response.Failure != nil || response.RequestID() != "request:01" {
		t.Fatalf("response = %#v", response)
	}
	if response.Success.SchemaVersion != workercontracts.RadarrRepairWorkerV1 ||
		response.Success.Operation != workercontracts.ProbeV1 ||
		response.Success.Status != workercontracts.Ok {
		t.Fatalf("response envelope = %#v", response.Success)
	}

	wantEvidence := completeWireEvidence()
	if !reflect.DeepEqual(response.Success.Evidence, wantEvidence) {
		t.Fatalf("evidence = %#v, want %#v", response.Success.Evidence, wantEvidence)
	}
	assertEncodes(t, response)
}

func TestSuccessResponsePreservesEmptyArrays(t *testing.T) {
	t.Parallel()

	response := SuccessResponse("request:empty", controller.ProbeEvidence{})
	if response.Success == nil {
		t.Fatal("success response is missing")
	}
	evidence := response.Success.Evidence
	if evidence.Format.Names == nil || evidence.Format.Tags == nil ||
		evidence.Streams == nil || evidence.Programs == nil || evidence.Chapters == nil {
		t.Fatalf("evidence contains nil arrays: %#v", evidence)
	}
	assertEncodes(t, response)
}

func TestSuccessResponsePreservesSignedChapterIDs(t *testing.T) {
	t.Parallel()

	evidence := completeEvidence()
	evidence.Chapters[0].ID = -5_887_710_727_936_598_178
	response := SuccessResponse("request:signed-chapter", evidence)
	if response.Success == nil ||
		response.Success.Evidence.Chapters[0].ID != -5_887_710_727_936_598_178 {
		t.Fatalf("response = %#v", response)
	}
	assertEncodes(t, response)
}

func TestFailureResponseBuildsWireEnvelope(t *testing.T) {
	t.Parallel()

	response := FailureResponse("request:02", workercontracts.FingerprintMismatch)
	if response.Kind != workercontracts.ProbeResponseFailed || response.Success != nil ||
		response.Failure == nil || response.RequestID() != "request:02" {
		t.Fatalf("response = %#v", response)
	}
	want := workercontracts.ProbeFailureResponseV1{
		Operation:     workercontracts.ProbeV1,
		Reason:        workercontracts.FingerprintMismatch,
		RequestID:     "request:02",
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
		Status:        workercontracts.Failed,
	}
	if !reflect.DeepEqual(*response.Failure, want) {
		t.Fatalf("failure = %#v, want %#v", *response.Failure, want)
	}
	assertEncodes(t, response)
}

func completeEvidence() controller.ProbeEvidence {
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names:        []string{"matroska", "webm"},
			LongName:     pointer("Matroska / WebM"),
			StreamCount:  pointer[int64](1),
			ProgramCount: pointer[int64](1),
			StartTimeMS:  pointer[int64](0),
			DurationMS:   pointer[int64](2000),
			SizeBytes:    pointer[int64](4096),
			BitRateBPS:   pointer[int64](16384),
			ProbeScore:   pointer[int64](100),
			Tags:         []controller.ProbeTag{{Name: "encoder", Value: "muxer"}},
		},
		Streams: []controller.ProbeStream{
			{
				Index:         0,
				Kind:          pointer(controller.ProbeStreamVideo),
				CodecName:     pointer("h264"),
				CodecLongName: pointer("H.264"),
				Profile:       pointer("High"),
				CodecTag:      pointer("avc1"),
				Width:         pointer[int64](1920),
				Height:        pointer[int64](1080),
				PixelFormat:   pointer("yuv420p"),
				SampleFormat:  pointer("fltp"),
				SampleRateHz:  pointer[int64](48000),
				Channels:      pointer[int64](2),
				ChannelLayout: pointer("stereo"),
				FrameRate:     &controller.Rational{Numerator: 24, Denominator: 1},
				AverageRate:   &controller.Rational{Numerator: 24000, Denominator: 1001},
				TimeBase:      &controller.Rational{Numerator: 1, Denominator: 1000},
				StartTicks:    pointer[int64](0),
				StartTimeMS:   pointer[int64](0),
				DurationTicks: pointer[int64](2000),
				DurationMS:    pointer[int64](2000),
				BitRateBPS:    pointer[int64](12000),
				FrameCount:    pointer[int64](48),
				Disposition: &controller.ProbeDisposition{
					Default:         pointer(true),
					Forced:          pointer(false),
					HearingImpaired: pointer(false),
					VisualImpaired:  pointer(false),
				},
				Tags: []controller.ProbeTag{{Name: "language", Value: "eng"}},
			},
		},
		Programs: []controller.ProbeProgram{
			{
				ID:            1,
				Number:        pointer[int64](2),
				StreamCount:   pointer[int64](1),
				PMTPID:        pointer[int64](100),
				PCRPID:        pointer[int64](101),
				StreamIndexes: []int64{0},
				Tags:          []controller.ProbeTag{{Name: "service_name", Value: "movie"}},
			},
		},
		Chapters: []controller.ProbeChapter{
			{
				ID:          1,
				TimeBase:    &controller.Rational{Numerator: 1, Denominator: 1000},
				StartTicks:  pointer[int64](0),
				StartTimeMS: pointer[int64](0),
				EndTicks:    pointer[int64](2000),
				EndTimeMS:   pointer[int64](2000),
				Tags:        []controller.ProbeTag{{Name: "title", Value: "Chapter 1"}},
			},
		},
	}
}

func completeWireEvidence() workercontracts.Evidence {
	return workercontracts.Evidence{
		Format: workercontracts.Format{
			Names:        []string{"matroska", "webm"},
			LongName:     pointer("Matroska / WebM"),
			StreamCount:  pointer[int64](1),
			ProgramCount: pointer[int64](1),
			StartTimeMS:  pointer[int64](0),
			DurationMS:   pointer[int64](2000),
			SizeBytes:    pointer[int64](4096),
			BitRateBps:   pointer[int64](16384),
			ProbeScore:   pointer[int64](100),
			Tags: []workercontracts.TagElement{
				{Name: workercontracts.Encoder, Value: "muxer"},
			},
		},
		Streams: []workercontracts.StreamElement{
			{
				Index:         0,
				Kind:          pointer(workercontracts.Video),
				CodecName:     pointer("h264"),
				CodecLongName: pointer("H.264"),
				Profile:       pointer("High"),
				CodecTag:      pointer("avc1"),
				Width:         pointer[int64](1920),
				Height:        pointer[int64](1080),
				PixelFormat:   pointer("yuv420p"),
				SampleFormat:  pointer("fltp"),
				SampleRateHz:  pointer[int64](48000),
				Channels:      pointer[int64](2),
				ChannelLayout: pointer("stereo"),
				FrameRate:     &workercontracts.TimeBaseClass{Numerator: 24, Denominator: 1},
				AverageRate:   &workercontracts.TimeBaseClass{Numerator: 24000, Denominator: 1001},
				TimeBase:      &workercontracts.TimeBaseClass{Numerator: 1, Denominator: 1000},
				StartTicks:    pointer[int64](0),
				StartTimeMS:   pointer[int64](0),
				DurationTicks: pointer[int64](2000),
				DurationMS:    pointer[int64](2000),
				BitRateBps:    pointer[int64](12000),
				FrameCount:    pointer[int64](48),
				Disposition: &workercontracts.DispositionClass{
					Default:         pointer(true),
					Forced:          pointer(false),
					HearingImpaired: pointer(false),
					VisualImpaired:  pointer(false),
				},
				Tags: []workercontracts.TagElement{
					{Name: workercontracts.Language, Value: "eng"},
				},
			},
		},
		Programs: []workercontracts.ProgramElement{
			{
				ID:            1,
				Number:        pointer[int64](2),
				StreamCount:   pointer[int64](1),
				PmtPID:        pointer[int64](100),
				PcrPID:        pointer[int64](101),
				StreamIndexes: []int64{0},
				Tags: []workercontracts.TagElement{
					{Name: workercontracts.ServiceName, Value: "movie"},
				},
			},
		},
		Chapters: []workercontracts.ChapterElement{
			{
				ID:          1,
				TimeBase:    &workercontracts.TimeBaseClass{Numerator: 1, Denominator: 1000},
				StartTicks:  pointer[int64](0),
				StartTimeMS: pointer[int64](0),
				EndTicks:    pointer[int64](2000),
				EndTimeMS:   pointer[int64](2000),
				Tags: []workercontracts.TagElement{
					{Name: workercontracts.Title, Value: "Chapter 1"},
				},
			},
		},
	}
}

func assertEncodes(t *testing.T, response workercontracts.ProbeResponseV1) {
	t.Helper()
	encoded, err := workercontracts.EncodeProbeResponse(response)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := workercontracts.DecodeProbeResponse(encoded); err != nil {
		t.Fatalf("decode encoded response: %v", err)
	}
}

func pointer[T any](value T) *T {
	return &value
}

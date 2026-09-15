package mediaevidence

import (
	"reflect"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

func TestFromProbeConvertsCompleteEvidence(t *testing.T) {
	t.Parallel()

	if got, want := FromProbe(completeEvidence()), completeWireEvidence(); !reflect.DeepEqual(got, want) {
		t.Fatalf("evidence = %#v, want %#v", got, want)
	}
}

func TestFromProbePreservesEmptyArrays(t *testing.T) {
	t.Parallel()

	evidence := FromProbe(controller.ProbeEvidence{})
	if evidence.Format.Names == nil || evidence.Format.Tags == nil ||
		evidence.Streams == nil || evidence.Programs == nil || evidence.Chapters == nil {
		t.Fatalf("evidence contains nil arrays: %#v", evidence)
	}
}

func TestFromProbePreservesSignedChapterIDs(t *testing.T) {
	t.Parallel()

	evidence := completeEvidence()
	evidence.Chapters[0].ID = -5_887_710_727_936_598_178
	converted := FromProbe(evidence)
	if converted.Chapters[0].ID != -5_887_710_727_936_598_178 {
		t.Fatalf("chapter = %#v", converted.Chapters[0])
	}
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

func pointer[T any](value T) *T {
	return &value
}

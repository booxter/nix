package joinverification

import (
	"slices"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
)

func TestValidateOutput(t *testing.T) {
	t.Parallel()

	for _, test := range []struct {
		name   string
		mutate func(*decisionpolicy.AuthorizedJoin, *controller.ProbeEvidence)
		want   RejectionReason
	}{
		{name: "valid"},
		{name: "size", want: ArtifactSizeMismatch, mutate: func(_ *decisionpolicy.AuthorizedJoin, evidence *controller.ProbeEvidence) {
			evidence.Format.SizeBytes = value[int64](189)
		}},
		{name: "short", want: DurationOutsideTolerance, mutate: duration(18_999)},
		{name: "long", want: DurationOutsideTolerance, mutate: duration(21_001)},
		{name: "lower boundary", mutate: duration(19_000)},
		{name: "upper boundary", mutate: duration(21_000)},
		{name: "missing duration", want: DurationUnavailable, mutate: func(_ *decisionpolicy.AuthorizedJoin, evidence *controller.ProbeEvidence) {
			evidence.Format.DurationMS = nil
			for index := range evidence.Streams {
				evidence.Streams[index].DurationMS = nil
			}
		}},
		{name: "container", want: OutputContainerMismatch, mutate: func(_ *decisionpolicy.AuthorizedJoin, evidence *controller.ProbeEvidence) {
			evidence.Format.Names = []string{"mp4"}
		}},
		{name: "changed stream", want: StreamLayoutMismatch, mutate: func(_ *decisionpolicy.AuthorizedJoin, evidence *controller.ProbeEvidence) {
			evidence.Streams[1].Channels = value[int64](6)
		}},
		{name: "reordered streams", want: StreamLayoutMismatch, mutate: func(_ *decisionpolicy.AuthorizedJoin, evidence *controller.ProbeEvidence) {
			evidence.Streams[0].Index = 1
			evidence.Streams[1].Index = 0
		}},
		{name: "MP4 muxer time base", mutate: func(authorized *decisionpolicy.AuthorizedJoin, evidence *controller.ProbeEvidence) {
			authorized.OutputContainer = controller.OutputContainerMP4
			evidence.Format.Names = []string{"mov", "mp4"}
			evidence.Streams[0].TimeBase = value(controller.Rational{Numerator: 1, Denominator: 12_800})
		}},
		{name: "muxed average rate", mutate: func(_ *decisionpolicy.AuthorizedJoin, evidence *controller.ProbeEvidence) {
			evidence.Streams[0].AverageRate = value(controller.Rational{Numerator: 965_825, Denominator: 38_634})
		}},
		{name: "AVI", mutate: func(authorized *decisionpolicy.AuthorizedJoin, evidence *controller.ProbeEvidence) {
			authorized.OutputContainer = controller.OutputContainerAVI
			evidence.Format.Names = []string{"avi"}
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			authorized, evidence := joinedOutput()
			if test.mutate != nil {
				test.mutate(&authorized, &evidence)
			}
			rejections := ValidateOutput(authorized, evidence, 190)
			if test.want == "" {
				if len(rejections) != 0 {
					t.Fatalf("valid output rejected: %+v", rejections)
				}
			} else if !slices.Contains(rejections, Rejection{Reason: test.want}) {
				t.Fatalf("rejections = %+v, want %s", rejections, test.want)
			}
		})
	}
}

func joinedOutput() (decisionpolicy.AuthorizedJoin, controller.ProbeEvidence) {
	timeBase := controller.Rational{Numerator: 1, Denominator: 1_000}
	frameRate := controller.Rational{Numerator: 25, Denominator: 1}
	layout := controller.StreamLayout{Streams: []controller.StreamLayoutEntry{
		{
			Kind: controller.ProbeStreamVideo, CodecName: "h264", TimeBase: timeBase,
			Video: &controller.VideoStreamLayout{Width: 1_920, Height: 1_080, PixelFormat: "yuv420p", AverageRate: frameRate},
		},
		{
			Kind: controller.ProbeStreamAudio, CodecName: "aac", TimeBase: timeBase,
			Audio: &controller.AudioStreamLayout{SampleFormat: "fltp", SampleRateHz: 48_000, Channels: 2, ChannelLayout: "stereo"},
		},
	}}
	authorized := decisionpolicy.AuthorizedJoin{
		ExpectedDurationMS: 20_000, DurationToleranceMS: 1_000,
		OutputContainer: controller.OutputContainerMKV, ExpectedStreamLayout: layout,
	}
	evidence := controller.ProbeEvidence{
		Format: controller.ProbeFormat{Names: []string{"matroska", "webm"}, DurationMS: value[int64](20_000), SizeBytes: value[int64](190)},
		Streams: []controller.ProbeStream{
			{
				Index: 0, Kind: value(controller.ProbeStreamVideo), CodecName: value("h264"), TimeBase: &timeBase,
				Width: value[int64](1_920), Height: value[int64](1_080), PixelFormat: value("yuv420p"), AverageRate: &frameRate,
				DurationMS: value[int64](20_000),
			},
			{
				Index: 1, Kind: value(controller.ProbeStreamAudio), CodecName: value("aac"), TimeBase: &timeBase,
				SampleFormat: value("fltp"), SampleRateHz: value[int64](48_000), Channels: value[int64](2), ChannelLayout: value("stereo"),
				DurationMS: value[int64](20_000),
			},
		},
	}
	return authorized, evidence
}

func duration(milliseconds int64) func(*decisionpolicy.AuthorizedJoin, *controller.ProbeEvidence) {
	return func(_ *decisionpolicy.AuthorizedJoin, evidence *controller.ProbeEvidence) {
		evidence.Format.DurationMS = value(milliseconds)
		for index := range evidence.Streams {
			evidence.Streams[index].DurationMS = value(milliseconds)
		}
	}
}

func value[T any](input T) *T {
	return &input
}

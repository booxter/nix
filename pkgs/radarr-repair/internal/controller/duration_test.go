package controller

import (
	"reflect"
	"testing"
)

func TestAssessProbeDuration(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		format  *int64
		streams []ProbeStream
		want    ProbeDurationAssessment
	}{
		{
			name: "missing durations",
			want: ProbeDurationAssessment{Source: DurationSourceUnknown},
		},
		{
			name:   "format only",
			format: durationPointer(12_000),
			want: ProbeDurationAssessment{
				FormatMS:    durationPointer(12_000),
				EffectiveMS: durationPointer(12_000),
				Source:      DurationSourceFormat,
			},
		},
		{
			name: "longest audio or video stream",
			streams: []ProbeStream{
				probeStream(ProbeStreamAudio, 11_000),
				probeStream(ProbeStreamVideo, 12_000),
			},
			want: ProbeDurationAssessment{
				LongestStreamMS: durationPointer(12_000),
				EffectiveMS:     durationPointer(12_000),
				Source:          DurationSourceLongestStream,
			},
		},
		{
			name:   "consistent observations use the larger duration",
			format: durationPointer(12_000),
			streams: []ProbeStream{
				probeStream(ProbeStreamVideo, 12_750),
			},
			want: ProbeDurationAssessment{
				FormatMS:        durationPointer(12_000),
				LongestStreamMS: durationPointer(12_750),
				EffectiveMS:     durationPointer(12_750),
				Source:          DurationSourceConsistentFormatAndStream,
			},
		},
		{
			name:   "agreement tolerance is inclusive",
			format: durationPointer(12_000),
			streams: []ProbeStream{
				probeStream(ProbeStreamVideo, 13_000),
			},
			want: ProbeDurationAssessment{
				FormatMS:        durationPointer(12_000),
				LongestStreamMS: durationPointer(13_000),
				EffectiveMS:     durationPointer(13_000),
				Source:          DurationSourceConsistentFormatAndStream,
			},
		},
		{
			name:   "conflicting observations have no effective duration",
			format: durationPointer(12_000),
			streams: []ProbeStream{
				probeStream(ProbeStreamVideo, 13_001),
			},
			want: ProbeDurationAssessment{
				FormatMS:        durationPointer(12_000),
				LongestStreamMS: durationPointer(13_001),
				Source:          DurationSourceUnknown,
				Conflict:        true,
			},
		},
		{
			name:   "zero durations are unusable",
			format: durationPointer(0),
			streams: []ProbeStream{
				probeStream(ProbeStreamVideo, 0),
			},
			want: ProbeDurationAssessment{Source: DurationSourceUnknown},
		},
		{
			name:   "non audiovisual streams are ignored",
			format: durationPointer(12_000),
			streams: []ProbeStream{
				probeStream(ProbeStreamVideo, 12_000),
				probeStream(ProbeStreamSubtitle, 90_000),
				probeStream(ProbeStreamAttachment, 120_000),
			},
			want: ProbeDurationAssessment{
				FormatMS:        durationPointer(12_000),
				LongestStreamMS: durationPointer(12_000),
				EffectiveMS:     durationPointer(12_000),
				Source:          DurationSourceConsistentFormatAndStream,
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			evidence := ProbeEvidence{
				Format:  ProbeFormat{DurationMS: test.format},
				Streams: test.streams,
			}
			got := AssessProbeDuration(evidence)
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("assessment = %#v, want %#v", got, test.want)
			}
		})
	}
}

func probeStream(kind ProbeStreamKind, durationMS int64) ProbeStream {
	return ProbeStream{Kind: &kind, DurationMS: durationPointer(durationMS)}
}

func durationPointer(value int64) *int64 {
	return &value
}

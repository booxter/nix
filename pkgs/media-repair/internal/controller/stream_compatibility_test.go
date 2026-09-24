package controller

import (
	"reflect"
	"testing"
)

func TestAssessStreamCompatibilityAcceptsMatchingSilentParts(t *testing.T) {
	t.Parallel()

	first := videoStream(0)
	first.StartTimeMS = pointerTo(int64(1_000))
	first.DurationMS = pointerTo(int64(10_000))
	first.BitRateBPS = pointerTo(int64(8_000_000))
	second := videoStream(4)
	second.StartTimeMS = pointerTo(int64(0))
	second.DurationMS = pointerTo(int64(20_000))
	second.BitRateBPS = pointerTo(int64(9_000_000))

	got := AssessStreamCompatibility(
		[]ProbeEvidence{{Streams: []ProbeStream{first}}, {Streams: []ProbeStream{second}}},
	)
	want := StreamLayout{Streams: []StreamLayoutEntry{{
		Kind:      ProbeStreamVideo,
		CodecName: "h264",
		Profile:   pointerTo("High"),
		TimeBase:  Rational{Numerator: 1, Denominator: 1_000},
		Video: &VideoStreamLayout{
			Width:       1_920,
			Height:      1_080,
			PixelFormat: "yuv420p",
			AverageRate: Rational{Numerator: 24_000, Denominator: 1_001},
		},
	}}}
	if got.Compatibility != StreamsCompatible || got.Issue != nil ||
		got.Layout == nil || !reflect.DeepEqual(*got.Layout, want) {
		t.Fatalf("assessment = %#v, want layout %#v", got, want)
	}
}

func TestAssessStreamCompatibilityAcceptsMatchingAudioVideoParts(t *testing.T) {
	t.Parallel()

	got := AssessStreamCompatibility(
		[]ProbeEvidence{
			{Streams: []ProbeStream{audioStream(1), videoStream(0)}},
			{Streams: []ProbeStream{videoStream(0), audioStream(1)}},
		},
	)
	if got.Compatibility != StreamsCompatible || got.Issue != nil || got.Layout == nil {
		t.Fatalf("assessment = %#v", got)
	}
	if got.Layout.Streams[0].Kind != ProbeStreamVideo ||
		got.Layout.Streams[1].Kind != ProbeStreamAudio {
		t.Fatalf("stream layout = %#v", got.Layout)
	}
}

func TestAssessStreamCompatibilityRejectsKnownDifferences(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*ProbeStream)
		field  StreamCompatibilityField
	}{
		{
			name: "codec",
			mutate: func(stream *ProbeStream) {
				stream.CodecName = pointerTo("hevc")
			},
			field: StreamFieldCodecName,
		},
		{
			name: "width",
			mutate: func(stream *ProbeStream) {
				stream.Width = pointerTo(int64(1280))
			},
			field: StreamFieldWidth,
		},
		{
			name: "frame rate",
			mutate: func(stream *ProbeStream) {
				stream.AverageRate = &Rational{Numerator: 25, Denominator: 1}
			},
			field: StreamFieldAverageFrameRate,
		},
		{
			name: "time base",
			mutate: func(stream *ProbeStream) {
				stream.TimeBase = &Rational{Numerator: 1, Denominator: 12_800}
			},
			field: StreamFieldTimeBase,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			candidate := videoStream(0)
			test.mutate(&candidate)
			got := AssessStreamCompatibility(
				[]ProbeEvidence{
					{Streams: []ProbeStream{videoStream(0)}},
					{Streams: []ProbeStream{candidate}},
				},
			)
			assertStreamIssue(
				t,
				got,
				StreamsIncompatible,
				StreamReasonLayoutMismatch,
				test.field,
			)
		})
	}
}

func TestAssessStreamCompatibilityRejectsAudioDifferences(t *testing.T) {
	t.Parallel()

	candidateAudio := audioStream(1)
	candidateAudio.Channels = pointerTo(int64(2))
	got := AssessStreamCompatibility(
		[]ProbeEvidence{
			{Streams: []ProbeStream{videoStream(0), audioStream(1)}},
			{Streams: []ProbeStream{videoStream(0), candidateAudio}},
		},
	)
	assertStreamIssue(
		t,
		got,
		StreamsIncompatible,
		StreamReasonLayoutMismatch,
		StreamFieldChannels,
	)
}

func TestAssessStreamCompatibilityRejectsDifferentStreamCounts(t *testing.T) {
	t.Parallel()

	partPosition := 1
	got := AssessStreamCompatibility(
		[]ProbeEvidence{
			{Streams: []ProbeStream{videoStream(0), audioStream(1)}},
			{Streams: []ProbeStream{videoStream(0)}},
		},
	)
	want := StreamCompatibilityAssessment{
		Compatibility: StreamsIncompatible,
		Issue: &StreamCompatibilityIssue{
			Reason:       StreamReasonStreamCountMismatch,
			PartPosition: &partPosition,
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("assessment = %#v, want %#v", got, want)
	}
}

func TestAssessStreamCompatibilityRequiresVideoButNotAudio(t *testing.T) {
	t.Parallel()

	partPosition := 0
	got := AssessStreamCompatibility(
		[]ProbeEvidence{
			{Streams: []ProbeStream{audioStream(0)}},
			{Streams: []ProbeStream{audioStream(0)}},
		},
	)
	want := StreamCompatibilityAssessment{
		Compatibility: StreamsIncompatible,
		Issue: &StreamCompatibilityIssue{
			Reason:       StreamReasonMissingVideo,
			PartPosition: &partPosition,
			Field:        StreamFieldKind,
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("assessment = %#v, want %#v", got, want)
	}
}

func TestAssessStreamCompatibilityReturnsUnknownForMissingEvidence(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name         string
		probes       []ProbeEvidence
		reason       StreamCompatibilityReason
		partPosition *int
	}{
		{
			name:   "too few parts",
			probes: []ProbeEvidence{{Streams: []ProbeStream{videoStream(0)}}},
			reason: StreamReasonTooFewParts,
		},
		{
			name: "missing probe",
			probes: []ProbeEvidence{
				{Streams: []ProbeStream{videoStream(0)}},
				{},
			},
			reason:       StreamReasonMissingProbe,
			partPosition: pointerTo(1),
		},
		{
			name: "missing required stream field",
			probes: []ProbeEvidence{
				{Streams: []ProbeStream{videoStream(0)}},
				{Streams: []ProbeStream{videoStreamWithoutTimeBase(0)}},
			},
			reason:       StreamReasonMissingMetadata,
			partPosition: pointerTo(1),
		},
		{
			name: "missing field in reference part",
			probes: []ProbeEvidence{
				{Streams: []ProbeStream{videoStreamWithoutTimeBase(0)}},
				{Streams: []ProbeStream{videoStream(0)}},
			},
			reason:       StreamReasonMissingMetadata,
			partPosition: pointerTo(0),
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got := AssessStreamCompatibility(test.probes)
			if got.Compatibility != StreamsUnknown || got.Issue == nil || got.Layout != nil ||
				got.Issue.Reason != test.reason ||
				!reflect.DeepEqual(got.Issue.PartPosition, test.partPosition) {
				t.Fatalf("assessment = %#v", got)
			}
		})
	}
}

func TestAssessStreamCompatibilityRequiresEveryStreamToMatch(t *testing.T) {
	t.Parallel()

	first := []ProbeStream{
		videoStream(0),
		audioStream(1),
		streamOfKind(2, ProbeStreamData, "bin_data"),
		streamOfKind(3, ProbeStreamSubtitle, "dvb_teletext"),
	}
	matching := []ProbeStream{
		videoStream(0),
		audioStream(1),
		streamOfKind(2, ProbeStreamData, "bin_data"),
		streamOfKind(3, ProbeStreamSubtitle, "dvb_teletext"),
	}
	got := AssessStreamCompatibility([]ProbeEvidence{{Streams: first}, {Streams: matching}})
	if got.Compatibility != StreamsCompatible || got.Issue != nil || got.Layout == nil {
		t.Fatalf("matching assessment = %#v", got)
	}

	second := []ProbeStream{videoStream(0), audioStream(1)}
	got = AssessStreamCompatibility([]ProbeEvidence{{Streams: first}, {Streams: second}})
	if got.Compatibility != StreamsIncompatible || got.Issue == nil ||
		got.Issue.Reason != StreamReasonStreamCountMismatch {
		t.Fatalf("assessment = %#v", got)
	}
}

func TestStreamLayoutMatchesMuxedOutput(t *testing.T) {
	t.Parallel()

	assessment := AssessStreamCompatibility([]ProbeEvidence{
		{Streams: []ProbeStream{videoStream(0), audioStream(1)}},
		{Streams: []ProbeStream{videoStream(0), audioStream(1)}},
	})
	if assessment.Layout == nil {
		t.Fatal("compatible streams did not produce a layout")
	}
	if !assessment.Layout.MatchesMuxedOutput([]ProbeStream{audioStream(1), videoStream(0)}) {
		t.Fatal("layout did not match streams returned out of array order")
	}
	muxed := []ProbeStream{videoStream(0), audioStream(1)}
	muxed[0].TimeBase = pointerTo(Rational{Numerator: 1, Denominator: 12_800})
	if !assessment.Layout.MatchesMuxedOutput(muxed) {
		t.Fatal("layout did not match a muxer-selected time base")
	}

	reordered := []ProbeStream{audioStream(0), videoStream(1)}
	if assessment.Layout.MatchesMuxedOutput(reordered) {
		t.Fatal("layout matched streams with different index order")
	}
	duplicateIndexes := []ProbeStream{videoStream(0), audioStream(0)}
	if assessment.Layout.MatchesMuxedOutput(duplicateIndexes) {
		t.Fatal("layout matched duplicate stream indexes")
	}

	changed := []ProbeStream{videoStream(0), audioStream(1)}
	changed[1].Channels = pointerTo(int64(2))
	if assessment.Layout.MatchesMuxedOutput(changed) {
		t.Fatal("layout matched changed audio")
	}
}

func TestStreamLayoutRejectsIncompleteEvidence(t *testing.T) {
	t.Parallel()

	layout := StreamLayout{Streams: []StreamLayoutEntry{{
		Kind:      ProbeStreamVideo,
		CodecName: "h264",
		TimeBase:  Rational{Numerator: 1, Denominator: 1_000},
		Video: &VideoStreamLayout{
			Width:       1_920,
			Height:      1_080,
			PixelFormat: "yuv420p",
			AverageRate: Rational{Numerator: 24_000, Denominator: 1_001},
		},
	}}}
	if layout.MatchesMuxedOutput([]ProbeStream{videoStreamWithoutTimeBase(0)}) {
		t.Fatal("layout matched incomplete stream evidence")
	}

	layout.Streams[0].Video = nil
	if layout.MatchesMuxedOutput([]ProbeStream{videoStream(0)}) {
		t.Fatal("malformed expected layout matched a stream")
	}
}

func assertStreamIssue(
	t *testing.T,
	assessment StreamCompatibilityAssessment,
	compatibility StreamCompatibility,
	reason StreamCompatibilityReason,
	field StreamCompatibilityField,
) {
	t.Helper()
	if assessment.Compatibility != compatibility || assessment.Issue == nil ||
		assessment.Issue.Reason != reason || assessment.Issue.Field != field ||
		assessment.Layout != nil {
		t.Fatalf("assessment = %#v", assessment)
	}
}

func videoStream(index int64) ProbeStream {
	return ProbeStream{
		Index:       index,
		Kind:        pointerTo(ProbeStreamVideo),
		CodecName:   pointerTo("h264"),
		Profile:     pointerTo("High"),
		Width:       pointerTo(int64(1920)),
		Height:      pointerTo(int64(1080)),
		PixelFormat: pointerTo("yuv420p"),
		AverageRate: &Rational{Numerator: 24_000, Denominator: 1_001},
		TimeBase:    &Rational{Numerator: 1, Denominator: 1_000},
	}
}

func videoStreamWithoutTimeBase(index int64) ProbeStream {
	stream := videoStream(index)
	stream.TimeBase = nil
	return stream
}

func audioStream(index int64) ProbeStream {
	return ProbeStream{
		Index:         index,
		Kind:          pointerTo(ProbeStreamAudio),
		CodecName:     pointerTo("ac3"),
		Profile:       nil,
		SampleFormat:  pointerTo("fltp"),
		SampleRateHz:  pointerTo(int64(48_000)),
		Channels:      pointerTo(int64(6)),
		ChannelLayout: pointerTo("5.1(side)"),
		TimeBase:      &Rational{Numerator: 1, Denominator: 1_000},
	}
}

func streamOfKind(index int64, kind ProbeStreamKind, codec string) ProbeStream {
	return ProbeStream{
		Index:     index,
		Kind:      pointerTo(kind),
		CodecName: pointerTo(codec),
		TimeBase:  &Rational{Numerator: 1, Denominator: 1_000},
	}
}

func pointerTo[T any](value T) *T {
	return &value
}

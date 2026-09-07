package controller

import (
	"cmp"
	"slices"
)

type StreamCompatibility string

const (
	StreamsCompatible   StreamCompatibility = "compatible"
	StreamsIncompatible StreamCompatibility = "incompatible"
	StreamsUnknown      StreamCompatibility = "unknown"
)

type StreamCompatibilityReason string

const (
	StreamReasonTooFewParts         StreamCompatibilityReason = "too_few_parts"
	StreamReasonMissingProbe        StreamCompatibilityReason = "missing_probe"
	StreamReasonMissingVideo        StreamCompatibilityReason = "missing_video"
	StreamReasonStreamCountMismatch StreamCompatibilityReason = "stream_count_mismatch"
	StreamReasonMissingMetadata     StreamCompatibilityReason = "missing_stream_metadata"
	StreamReasonLayoutMismatch      StreamCompatibilityReason = "stream_layout_mismatch"
)

type StreamCompatibilityField string

const (
	StreamFieldKind             StreamCompatibilityField = "kind"
	StreamFieldCodecName        StreamCompatibilityField = "codec_name"
	StreamFieldProfile          StreamCompatibilityField = "profile"
	StreamFieldTimeBase         StreamCompatibilityField = "time_base"
	StreamFieldWidth            StreamCompatibilityField = "width"
	StreamFieldHeight           StreamCompatibilityField = "height"
	StreamFieldPixelFormat      StreamCompatibilityField = "pixel_format"
	StreamFieldAverageFrameRate StreamCompatibilityField = "average_frame_rate"
	StreamFieldSampleFormat     StreamCompatibilityField = "sample_format"
	StreamFieldSampleRate       StreamCompatibilityField = "sample_rate_hz"
	StreamFieldChannels         StreamCompatibilityField = "channels"
	StreamFieldChannelLayout    StreamCompatibilityField = "channel_layout"
)

type StreamCompatibilityIssue struct {
	Reason         StreamCompatibilityReason
	PartPosition   *int
	StreamPosition *int
	Field          StreamCompatibilityField
}

type StreamCompatibilityAssessment struct {
	Compatibility StreamCompatibility
	Issue         *StreamCompatibilityIssue
}

func AssessStreamCompatibility(probes []ProbeEvidence) StreamCompatibilityAssessment {
	if len(probes) < 2 {
		return streamAssessment(StreamsUnknown, StreamReasonTooFewParts, nil, nil, "")
	}

	streams := make([][]ProbeStream, len(probes))
	var firstUnknown *StreamCompatibilityIssue
	referencePosition := -1
	for partPosition, probe := range probes {
		if len(probe.Streams) == 0 {
			if firstUnknown == nil {
				firstUnknown = streamIssue(StreamReasonMissingProbe, &partPosition, nil, "")
			}
			continue
		}
		streams[partPosition] = orderedStreams(probe.Streams)
		if referencePosition == -1 {
			referencePosition = partPosition
		}
		hasVideo, hasUnknownKind := videoPresence(streams[partPosition])
		if !hasVideo && !hasUnknownKind {
			return streamAssessment(
				StreamsIncompatible,
				StreamReasonMissingVideo,
				&partPosition,
				nil,
				StreamFieldKind,
			)
		}
		if !hasVideo && firstUnknown == nil {
			firstUnknown = streamIssue(
				StreamReasonMissingMetadata,
				&partPosition,
				nil,
				StreamFieldKind,
			)
		}
	}

	if referencePosition == -1 {
		return StreamCompatibilityAssessment{Compatibility: StreamsUnknown, Issue: firstUnknown}
	}
	reference := streams[referencePosition]
	for partPosition := range streams {
		if partPosition == referencePosition || len(probes[partPosition].Streams) == 0 {
			continue
		}
		if len(streams[partPosition]) != len(reference) {
			return streamAssessment(
				StreamsIncompatible,
				StreamReasonStreamCountMismatch,
				&partPosition,
				nil,
				"",
			)
		}
		for streamPosition := range reference {
			comparison := compareStreams(reference[streamPosition], streams[partPosition][streamPosition])
			if comparison.mismatch != "" {
				return streamAssessment(
					StreamsIncompatible,
					StreamReasonLayoutMismatch,
					&partPosition,
					&streamPosition,
					comparison.mismatch,
				)
			}
			if comparison.missing != "" && firstUnknown == nil {
				missingPartPosition := partPosition
				if comparison.missingReference {
					missingPartPosition = referencePosition
				}
				firstUnknown = streamIssue(
					StreamReasonMissingMetadata,
					&missingPartPosition,
					&streamPosition,
					comparison.missing,
				)
			}
		}
	}

	if firstUnknown != nil {
		return StreamCompatibilityAssessment{Compatibility: StreamsUnknown, Issue: firstUnknown}
	}
	return StreamCompatibilityAssessment{Compatibility: StreamsCompatible}
}

func orderedStreams(streams []ProbeStream) []ProbeStream {
	ordered := slices.Clone(streams)
	slices.SortFunc(ordered, func(left ProbeStream, right ProbeStream) int {
		return cmp.Compare(left.Index, right.Index)
	})
	return ordered
}

func videoPresence(streams []ProbeStream) (bool, bool) {
	unknown := false
	for _, stream := range streams {
		if stream.Kind == nil {
			unknown = true
		} else if *stream.Kind == ProbeStreamVideo {
			return true, unknown
		}
	}
	return false, unknown
}

type streamComparison struct {
	missing          StreamCompatibilityField
	missingReference bool
	mismatch         StreamCompatibilityField
}

func compareStreams(reference ProbeStream, candidate ProbeStream) streamComparison {
	comparison := streamComparison{}
	compareRequiredField(&comparison, StreamFieldKind, reference.Kind, candidate.Kind)
	compareRequiredField(&comparison, StreamFieldCodecName, reference.CodecName, candidate.CodecName)
	compareOptionalField(&comparison, StreamFieldProfile, reference.Profile, candidate.Profile)
	compareRequiredField(&comparison, StreamFieldTimeBase, reference.TimeBase, candidate.TimeBase)
	if reference.Kind == nil || candidate.Kind == nil || *reference.Kind != *candidate.Kind {
		return comparison
	}

	switch *reference.Kind {
	case ProbeStreamVideo:
		compareRequiredField(&comparison, StreamFieldWidth, reference.Width, candidate.Width)
		compareRequiredField(&comparison, StreamFieldHeight, reference.Height, candidate.Height)
		compareRequiredField(
			&comparison,
			StreamFieldPixelFormat,
			reference.PixelFormat,
			candidate.PixelFormat,
		)
		compareRequiredField(
			&comparison,
			StreamFieldAverageFrameRate,
			reference.AverageRate,
			candidate.AverageRate,
		)
	case ProbeStreamAudio:
		compareRequiredField(
			&comparison,
			StreamFieldSampleFormat,
			reference.SampleFormat,
			candidate.SampleFormat,
		)
		compareRequiredField(
			&comparison,
			StreamFieldSampleRate,
			reference.SampleRateHz,
			candidate.SampleRateHz,
		)
		compareRequiredField(&comparison, StreamFieldChannels, reference.Channels, candidate.Channels)
		compareRequiredField(
			&comparison,
			StreamFieldChannelLayout,
			reference.ChannelLayout,
			candidate.ChannelLayout,
		)
	}
	return comparison
}

func compareRequiredField[T comparable](
	comparison *streamComparison,
	field StreamCompatibilityField,
	reference *T,
	candidate *T,
) {
	if reference == nil || candidate == nil {
		if comparison.missing == "" {
			comparison.missing = field
			comparison.missingReference = reference == nil
		}
		return
	}
	if *reference != *candidate && comparison.mismatch == "" {
		comparison.mismatch = field
	}
}

func compareOptionalField[T comparable](
	comparison *streamComparison,
	field StreamCompatibilityField,
	reference *T,
	candidate *T,
) {
	if reference == nil && candidate == nil {
		return
	}
	compareRequiredField(comparison, field, reference, candidate)
}

func streamAssessment(
	compatibility StreamCompatibility,
	reason StreamCompatibilityReason,
	partPosition *int,
	streamPosition *int,
	field StreamCompatibilityField,
) StreamCompatibilityAssessment {
	return StreamCompatibilityAssessment{
		Compatibility: compatibility,
		Issue:         streamIssue(reason, partPosition, streamPosition, field),
	}
}

func streamIssue(
	reason StreamCompatibilityReason,
	partPosition *int,
	streamPosition *int,
	field StreamCompatibilityField,
) *StreamCompatibilityIssue {
	return &StreamCompatibilityIssue{
		Reason:         reason,
		PartPosition:   copiedInt(partPosition),
		StreamPosition: copiedInt(streamPosition),
		Field:          field,
	}
}

func copiedInt(value *int) *int {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

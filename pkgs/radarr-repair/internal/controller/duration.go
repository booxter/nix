package controller

const durationAgreementToleranceMS int64 = 1_000

type EffectiveDurationSource string

const (
	DurationSourceFormat                    EffectiveDurationSource = "format"
	DurationSourceLongestStream             EffectiveDurationSource = "longest_stream"
	DurationSourceConsistentFormatAndStream EffectiveDurationSource = "consistent_format_and_stream"
	DurationSourceUnknown                   EffectiveDurationSource = "unknown"
)

type ProbeDurationAssessment struct {
	FormatMS        *int64
	LongestStreamMS *int64
	EffectiveMS     *int64
	Source          EffectiveDurationSource
	Conflict        bool
}

func AssessProbeDuration(evidence ProbeEvidence) ProbeDurationAssessment {
	formatDuration := usableDuration(evidence.Format.DurationMS)
	streamDuration := longestAVStreamDuration(evidence.Streams)
	assessment := ProbeDurationAssessment{
		FormatMS:        formatDuration,
		LongestStreamMS: streamDuration,
		Source:          DurationSourceUnknown,
	}

	switch {
	case formatDuration == nil && streamDuration == nil:
		return assessment
	case streamDuration == nil:
		assessment.EffectiveMS = int64Value(*formatDuration)
		assessment.Source = DurationSourceFormat
		return assessment
	case formatDuration == nil:
		assessment.EffectiveMS = int64Value(*streamDuration)
		assessment.Source = DurationSourceLongestStream
		return assessment
	}

	shorter, longer := *formatDuration, *streamDuration
	if shorter > longer {
		shorter, longer = longer, shorter
	}
	if longer-shorter > durationAgreementToleranceMS {
		assessment.Conflict = true
		return assessment
	}

	assessment.EffectiveMS = int64Value(longer)
	assessment.Source = DurationSourceConsistentFormatAndStream
	return assessment
}

func longestAVStreamDuration(streams []ProbeStream) *int64 {
	var longest *int64
	for _, stream := range streams {
		if stream.Kind == nil ||
			(*stream.Kind != ProbeStreamVideo && *stream.Kind != ProbeStreamAudio) {
			continue
		}
		duration := usableDuration(stream.DurationMS)
		if duration != nil && (longest == nil || *duration > *longest) {
			longest = duration
		}
	}
	return longest
}

func usableDuration(duration *int64) *int64 {
	if duration == nil || *duration <= 0 {
		return nil
	}
	return int64Value(*duration)
}

func int64Value(value int64) *int64 {
	return &value
}

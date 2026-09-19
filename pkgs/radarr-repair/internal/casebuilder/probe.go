package casebuilder

import (
	"errors"
	"fmt"
	"slices"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

var errIncompleteProbeMetadata = errors.New("probe metadata is incomplete")

func mapFile(
	assessment controller.MediaFileAssessment,
	outcome controller.MediaProbeOutcome,
) (contracts.FileElement, error) {
	file := assessment.File
	probe, err := mapProbe(outcome, file.Fingerprint.SizeBytes)
	if err != nil {
		return contracts.FileElement{}, err
	}
	if assessment.ProbeCandidate() && outcome.Status == controller.MediaProbeNotCollected &&
		outcome.Reason == controller.MediaProbeNotCandidate {
		return contracts.FileElement{}, fmt.Errorf("probe candidate was marked as ineligible for probing")
	}
	if !assessment.ProbeCandidate() && (outcome.Status != controller.MediaProbeNotCollected ||
		outcome.Reason != controller.MediaProbeNotCandidate) {
		return contracts.FileElement{}, fmt.Errorf("evidence-only file has an invalid probe outcome")
	}

	var membership *contracts.DownloadMembershipClass
	if file.DownloadFile != nil {
		var sourceIndex *int64
		if file.DownloadFile.HasIndex {
			mapped := int64(file.DownloadFile.Index)
			sourceIndex = &mapped
		}
		membership = &contracts.DownloadMembershipClass{
			SourceIndex:     sourceIndex,
			Selected:        file.DownloadFile.Selected,
			SourceSizeBytes: file.DownloadFile.LengthBytes,
			AvailableBytes:  file.DownloadFile.BytesCompleted,
		}
	}
	var extension *contracts.Extension
	if assessment.Extension != "" {
		mapped := contracts.Extension(assessment.Extension)
		extension = &mapped
	}
	var dispositionReason *contracts.DispositionReason
	if assessment.ExclusionReason != "" {
		mapped := contracts.DispositionReason(assessment.ExclusionReason)
		dispositionReason = &mapped
	}
	return contracts.FileElement{
		FileID:             string(file.ID),
		PathComponents:     clone(file.PathComponents),
		SizeBytes:          file.Fingerprint.SizeBytes,
		DownloadMembership: membership,
		Fingerprint:        file.Fingerprint.Fingerprint(),
		Extension:          extension,
		Disposition:        contracts.DispositionEnum(assessment.Disposition),
		DispositionReason:  dispositionReason,
		Probe:              probe,
	}, nil
}

func mapProbe(outcome controller.MediaProbeOutcome, expectedSize int64) (contracts.Probe, error) {
	switch outcome.Status {
	case controller.MediaProbeSucceeded:
		if outcome.Evidence == nil || outcome.Reason != "" {
			return contracts.Probe{}, fmt.Errorf("successful probe outcome is incomplete")
		}
		probe, err := mapSuccessfulProbe(*outcome.Evidence, expectedSize)
		if errors.Is(err, errIncompleteProbeMetadata) {
			return unavailableProbe(
				controller.MediaProbeFailed,
				controller.MediaProbeIncompleteMetadata,
			), nil
		}
		return probe, err
	case controller.MediaProbeFailed:
		if outcome.Evidence != nil || !failedProbeReason(outcome.Reason) {
			return contracts.Probe{}, fmt.Errorf("failed probe outcome is invalid")
		}
	case controller.MediaProbeNotCollected:
		if outcome.Evidence != nil || !uncollectedProbeReason(outcome.Reason) {
			return contracts.Probe{}, fmt.Errorf("uncollected probe outcome is invalid")
		}
	default:
		return contracts.Probe{}, fmt.Errorf("probe outcome status %q is invalid", outcome.Status)
	}
	return unavailableProbe(outcome.Status, outcome.Reason), nil
}

func unavailableProbe(
	status controller.MediaProbeStatus,
	reason controller.MediaProbeReason,
) contracts.Probe {
	mappedReason := contracts.ProbeReason(reason)
	summary := probeSummary(reason)
	return contracts.Probe{
		Status: contracts.Status(status), Reason: &mappedReason, Summary: &summary,
	}
}

func mapSuccessfulProbe(evidence controller.ProbeEvidence, expectedSize int64) (contracts.Probe, error) {
	if evidence.Format.SizeBytes == nil {
		return contracts.Probe{}, fmt.Errorf(
			"%w: format size is missing",
			errIncompleteProbeMetadata,
		)
	}
	if *evidence.Format.SizeBytes != expectedSize {
		return contracts.Probe{}, fmt.Errorf(
			"probe format size %d does not match inventory size %d",
			*evidence.Format.SizeBytes,
			expectedSize,
		)
	}
	duration := controller.AssessProbeDuration(evidence)
	streams := slices.Clone(evidence.Streams)
	slices.SortFunc(streams, func(left, right controller.ProbeStream) int {
		if left.Index < right.Index {
			return -1
		}
		if left.Index > right.Index {
			return 1
		}
		return 0
	})
	mappedStreams := make([]contracts.StreamElement, len(streams))
	for index, stream := range streams {
		if index > 0 && stream.Index == streams[index-1].Index {
			return contracts.Probe{}, fmt.Errorf("probe contains duplicate stream index %d", stream.Index)
		}
		mapped, err := mapStream(stream)
		if err != nil {
			return contracts.Probe{}, fmt.Errorf("stream %d: %w", stream.Index, err)
		}
		mappedStreams[index] = mapped
	}
	format := contracts.FormatClass{
		Names:                   clone(evidence.Format.Names),
		EffectiveDurationMS:     duration.EffectiveMS,
		EffectiveDurationSource: contracts.EffectiveDurationSource(duration.Source),
		FormatDurationMS:        duration.FormatMS,
		LongestStreamDurationMS: duration.LongestStreamMS,
		SizeBytes:               *evidence.Format.SizeBytes,
		BitRateBps:              evidence.Format.BitRateBPS,
	}
	return contracts.Probe{Status: contracts.Ok, Format: &format, Streams: mappedStreams}, nil
}

func failedProbeReason(reason controller.MediaProbeReason) bool {
	switch reason {
	case controller.MediaProbeNotRegularFile,
		controller.MediaProbeUnsupportedFormat,
		controller.MediaProbeTimeout,
		controller.MediaProbeError,
		controller.MediaProbeInvalidOutput,
		controller.MediaProbeIncompleteMetadata:
		return true
	default:
		return false
	}
}

func uncollectedProbeReason(reason controller.MediaProbeReason) bool {
	return reason == controller.MediaProbeNotCandidate ||
		reason == controller.MediaProbeCollectionLimit
}

func probeSummary(reason controller.MediaProbeReason) string {
	switch reason {
	case controller.MediaProbeNotRegularFile:
		return "The worker did not observe a regular file."
	case controller.MediaProbeUnsupportedFormat:
		return "ffprobe did not recognize a supported media format."
	case controller.MediaProbeTimeout:
		return "Media probing reached its execution deadline."
	case controller.MediaProbeError:
		return "ffprobe failed while inspecting the file."
	case controller.MediaProbeInvalidOutput:
		return "ffprobe returned invalid structured metadata."
	case controller.MediaProbeIncompleteMetadata:
		return "ffprobe omitted metadata required by the planner."
	case controller.MediaProbeNotCandidate:
		return "The file was retained as evidence but was not eligible for probing."
	case controller.MediaProbeCollectionLimit:
		return "The collection deadline was reached before the file could be probed."
	default:
		return "Media probe evidence is unavailable."
	}
}

func mapStream(stream controller.ProbeStream) (contracts.StreamElement, error) {
	if stream.Kind == nil {
		return contracts.StreamElement{}, fmt.Errorf("%w: kind is missing", errIncompleteProbeMetadata)
	}
	if stream.CodecName == nil {
		return contracts.StreamElement{}, fmt.Errorf(
			"%w: codec name is missing",
			errIncompleteProbeMetadata,
		)
	}
	if stream.TimeBase == nil {
		return contracts.StreamElement{}, fmt.Errorf(
			"%w: time base is missing",
			errIncompleteProbeMetadata,
		)
	}
	if stream.Disposition == nil || stream.Disposition.Default == nil ||
		stream.Disposition.Forced == nil || stream.Disposition.HearingImpaired == nil ||
		stream.Disposition.VisualImpaired == nil {
		return contracts.StreamElement{}, fmt.Errorf(
			"%w: disposition is incomplete",
			errIncompleteProbeMetadata,
		)
	}

	return contracts.StreamElement{
		Index:       stream.Index,
		Kind:        contracts.StreamKind(*stream.Kind),
		CodecName:   *stream.CodecName,
		CodecTag:    stream.CodecTag,
		Profile:     stream.Profile,
		TimeBase:    mapRational(*stream.TimeBase),
		StartTimeMS: stream.StartTimeMS,
		DurationMS:  stream.DurationMS,
		BitRateBps:  stream.BitRateBPS,
		Language:    streamLanguage(stream.Tags),
		Disposition: contracts.DispositionClass{
			Default:         *stream.Disposition.Default,
			Forced:          *stream.Disposition.Forced,
			HearingImpaired: *stream.Disposition.HearingImpaired,
			VisualImpaired:  *stream.Disposition.VisualImpaired,
		},
		Width:         stream.Width,
		Height:        stream.Height,
		PixelFormat:   stream.PixelFormat,
		FrameRate:     mapOptionalRational(stream.AverageRate),
		SampleRateHz:  stream.SampleRateHz,
		Channels:      stream.Channels,
		ChannelLayout: stream.ChannelLayout,
	}, nil
}

func mapRational(value controller.Rational) contracts.FrameRate {
	return contracts.FrameRate{Numerator: value.Numerator, Denominator: value.Denominator}
}

func mapOptionalRational(value *controller.Rational) *contracts.FrameRate {
	if value == nil {
		return nil
	}
	mapped := mapRational(*value)
	return &mapped
}

func streamLanguage(tags []controller.ProbeTag) *string {
	for _, tag := range tags {
		if tag.Name == "language" {
			language := tag.Value
			return &language
		}
	}
	return nil
}

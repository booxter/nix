package casebuilder

import (
	"fmt"
	"slices"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

func mapFile(
	file controller.InventoryFile,
	extension controller.MediaExtension,
	evidence controller.ProbeEvidence,
) (contracts.FileElement, error) {
	if file.TorrentFile == nil {
		return contracts.FileElement{}, fmt.Errorf("torrent reference is missing")
	}
	probe, err := mapProbe(evidence, file.Fingerprint.SizeBytes)
	if err != nil {
		return contracts.FileElement{}, err
	}
	torrentIndex := int64(file.TorrentFile.Index)
	wanted := file.TorrentFile.Wanted
	bytesCompleted := file.TorrentFile.BytesCompleted
	mappedExtension := contracts.Extension(extension)
	return contracts.FileElement{
		FileID:            string(file.ID),
		PathComponents:    clone(file.PathComponents),
		SizeBytes:         file.Fingerprint.SizeBytes,
		TorrentIndex:      &torrentIndex,
		Wanted:            &wanted,
		BytesCompleted:    &bytesCompleted,
		Fingerprint:       file.Fingerprint.Fingerprint(),
		Extension:         &mappedExtension,
		Disposition:       contracts.DispositionEnum(controller.MediaFileProbeCandidate),
		DispositionReason: nil,
		Probe:             probe,
	}, nil
}

func mapProbe(evidence controller.ProbeEvidence, expectedSize int64) (contracts.Probe, error) {
	if evidence.Format.SizeBytes == nil {
		return contracts.Probe{}, fmt.Errorf("probe format size is missing")
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

func mapStream(stream controller.ProbeStream) (contracts.StreamElement, error) {
	if stream.Kind == nil {
		return contracts.StreamElement{}, fmt.Errorf("kind is missing")
	}
	if stream.CodecName == nil {
		return contracts.StreamElement{}, fmt.Errorf("codec name is missing")
	}
	if stream.TimeBase == nil {
		return contracts.StreamElement{}, fmt.Errorf("time base is missing")
	}
	if stream.Disposition == nil || stream.Disposition.Default == nil ||
		stream.Disposition.Forced == nil || stream.Disposition.HearingImpaired == nil ||
		stream.Disposition.VisualImpaired == nil {
		return contracts.StreamElement{}, fmt.Errorf("disposition is incomplete")
	}

	return contracts.StreamElement{
		Index:       stream.Index,
		Kind:        contracts.Kind(*stream.Kind),
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

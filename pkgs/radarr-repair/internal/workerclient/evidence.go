package workerclient

import (
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

func convertEvidence(evidence workercontracts.Evidence) controller.ProbeEvidence {
	streams := make([]controller.ProbeStream, len(evidence.Streams))
	for index, stream := range evidence.Streams {
		streams[index] = convertStream(stream)
	}
	programs := make([]controller.ProbeProgram, len(evidence.Programs))
	for index, program := range evidence.Programs {
		programs[index] = convertProgram(program)
	}
	chapters := make([]controller.ProbeChapter, len(evidence.Chapters))
	for index, chapter := range evidence.Chapters {
		chapters[index] = convertChapter(chapter)
	}
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names:        copySlice(evidence.Format.Names),
			LongName:     copyPointer(evidence.Format.LongName),
			StreamCount:  copyPointer(evidence.Format.StreamCount),
			ProgramCount: copyPointer(evidence.Format.ProgramCount),
			StartTimeMS:  copyPointer(evidence.Format.StartTimeMS),
			DurationMS:   copyPointer(evidence.Format.DurationMS),
			SizeBytes:    copyPointer(evidence.Format.SizeBytes),
			BitRateBPS:   copyPointer(evidence.Format.BitRateBps),
			ProbeScore:   copyPointer(evidence.Format.ProbeScore),
			Tags:         convertTags(evidence.Format.Tags),
		},
		Streams:  streams,
		Programs: programs,
		Chapters: chapters,
	}
}

func convertStream(stream workercontracts.StreamElement) controller.ProbeStream {
	return controller.ProbeStream{
		Index:         stream.Index,
		Kind:          convertKind(stream.Kind),
		CodecName:     copyPointer(stream.CodecName),
		CodecLongName: copyPointer(stream.CodecLongName),
		Profile:       copyPointer(stream.Profile),
		CodecTag:      copyPointer(stream.CodecTag),
		Width:         copyPointer(stream.Width),
		Height:        copyPointer(stream.Height),
		PixelFormat:   copyPointer(stream.PixelFormat),
		SampleFormat:  copyPointer(stream.SampleFormat),
		SampleRateHz:  copyPointer(stream.SampleRateHz),
		Channels:      copyPointer(stream.Channels),
		ChannelLayout: copyPointer(stream.ChannelLayout),
		FrameRate:     convertRational(stream.FrameRate),
		AverageRate:   convertRational(stream.AverageRate),
		TimeBase:      convertRational(stream.TimeBase),
		StartTicks:    copyPointer(stream.StartTicks),
		StartTimeMS:   copyPointer(stream.StartTimeMS),
		DurationTicks: copyPointer(stream.DurationTicks),
		DurationMS:    copyPointer(stream.DurationMS),
		BitRateBPS:    copyPointer(stream.BitRateBps),
		FrameCount:    copyPointer(stream.FrameCount),
		Disposition:   convertDisposition(stream.Disposition),
		Tags:          convertTags(stream.Tags),
	}
}

func convertProgram(program workercontracts.ProgramElement) controller.ProbeProgram {
	return controller.ProbeProgram{
		ID:            program.ID,
		Number:        copyPointer(program.Number),
		StreamCount:   copyPointer(program.StreamCount),
		PMTPID:        copyPointer(program.PmtPID),
		PCRPID:        copyPointer(program.PcrPID),
		StreamIndexes: copySlice(program.StreamIndexes),
		Tags:          convertTags(program.Tags),
	}
}

func convertChapter(chapter workercontracts.ChapterElement) controller.ProbeChapter {
	return controller.ProbeChapter{
		ID:          chapter.ID,
		TimeBase:    convertRational(chapter.TimeBase),
		StartTicks:  copyPointer(chapter.StartTicks),
		StartTimeMS: copyPointer(chapter.StartTimeMS),
		EndTicks:    copyPointer(chapter.EndTicks),
		EndTimeMS:   copyPointer(chapter.EndTimeMS),
		Tags:        convertTags(chapter.Tags),
	}
}

func convertKind(kind *workercontracts.Kind) *controller.ProbeStreamKind {
	if kind == nil {
		return nil
	}
	converted := controller.ProbeStreamKind(*kind)
	return &converted
}

func convertRational(rational *workercontracts.TimeBaseClass) *controller.Rational {
	if rational == nil {
		return nil
	}
	return &controller.Rational{
		Numerator: rational.Numerator, Denominator: rational.Denominator,
	}
}

func convertDisposition(
	disposition *workercontracts.DispositionClass,
) *controller.ProbeDisposition {
	if disposition == nil {
		return nil
	}
	return &controller.ProbeDisposition{
		Default:         copyPointer(disposition.Default),
		Forced:          copyPointer(disposition.Forced),
		HearingImpaired: copyPointer(disposition.HearingImpaired),
		VisualImpaired:  copyPointer(disposition.VisualImpaired),
	}
}

func convertTags(tags []workercontracts.TagElement) []controller.ProbeTag {
	converted := make([]controller.ProbeTag, len(tags))
	for index, tag := range tags {
		converted[index] = controller.ProbeTag{Name: string(tag.Name), Value: tag.Value}
	}
	return converted
}

func copyPointer[T any](value *T) *T {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func copySlice[T any](values []T) []T {
	result := make([]T, len(values))
	copy(result, values)
	return result
}

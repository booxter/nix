package mediaevidence

import (
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

func FromProbe(evidence controller.ProbeEvidence) workercontracts.Evidence {
	streams := make([]workercontracts.StreamElement, len(evidence.Streams))
	for index, stream := range evidence.Streams {
		streams[index] = convertStream(stream)
	}
	programs := make([]workercontracts.ProgramElement, len(evidence.Programs))
	for index, program := range evidence.Programs {
		programs[index] = convertProgram(program)
	}
	chapters := make([]workercontracts.ChapterElement, len(evidence.Chapters))
	for index, chapter := range evidence.Chapters {
		chapters[index] = convertChapter(chapter)
	}
	return workercontracts.Evidence{
		Format:   convertFormat(evidence.Format),
		Streams:  streams,
		Programs: programs,
		Chapters: chapters,
	}
}

func convertFormat(format controller.ProbeFormat) workercontracts.Format {
	names := make([]string, len(format.Names))
	copy(names, format.Names)
	return workercontracts.Format{
		Names:        names,
		LongName:     copyPointer(format.LongName),
		StreamCount:  copyPointer(format.StreamCount),
		ProgramCount: copyPointer(format.ProgramCount),
		StartTimeMS:  copyPointer(format.StartTimeMS),
		DurationMS:   copyPointer(format.DurationMS),
		SizeBytes:    copyPointer(format.SizeBytes),
		BitRateBps:   copyPointer(format.BitRateBPS),
		ProbeScore:   copyPointer(format.ProbeScore),
		Tags:         convertTags(format.Tags),
	}
}

func convertStream(stream controller.ProbeStream) workercontracts.StreamElement {
	return workercontracts.StreamElement{
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
		BitRateBps:    copyPointer(stream.BitRateBPS),
		FrameCount:    copyPointer(stream.FrameCount),
		Disposition:   convertDisposition(stream.Disposition),
		Tags:          convertTags(stream.Tags),
	}
}

func convertProgram(program controller.ProbeProgram) workercontracts.ProgramElement {
	streamIndexes := make([]int64, len(program.StreamIndexes))
	copy(streamIndexes, program.StreamIndexes)
	return workercontracts.ProgramElement{
		ID:            program.ID,
		Number:        copyPointer(program.Number),
		StreamCount:   copyPointer(program.StreamCount),
		PmtPID:        copyPointer(program.PMTPID),
		PcrPID:        copyPointer(program.PCRPID),
		StreamIndexes: streamIndexes,
		Tags:          convertTags(program.Tags),
	}
}

func convertChapter(chapter controller.ProbeChapter) workercontracts.ChapterElement {
	return workercontracts.ChapterElement{
		ID:          chapter.ID,
		TimeBase:    convertRational(chapter.TimeBase),
		StartTicks:  copyPointer(chapter.StartTicks),
		StartTimeMS: copyPointer(chapter.StartTimeMS),
		EndTicks:    copyPointer(chapter.EndTicks),
		EndTimeMS:   copyPointer(chapter.EndTimeMS),
		Tags:        convertTags(chapter.Tags),
	}
}

func convertKind(kind *controller.ProbeStreamKind) *workercontracts.StreamKind {
	if kind == nil {
		return nil
	}
	converted := workercontracts.StreamKind(*kind)
	return &converted
}

func convertRational(rational *controller.Rational) *workercontracts.TimeBaseClass {
	if rational == nil {
		return nil
	}
	return &workercontracts.TimeBaseClass{
		Numerator:   rational.Numerator,
		Denominator: rational.Denominator,
	}
}

func convertDisposition(
	disposition *controller.ProbeDisposition,
) *workercontracts.DispositionClass {
	if disposition == nil {
		return nil
	}
	return &workercontracts.DispositionClass{
		Default:         copyPointer(disposition.Default),
		Forced:          copyPointer(disposition.Forced),
		HearingImpaired: copyPointer(disposition.HearingImpaired),
		VisualImpaired:  copyPointer(disposition.VisualImpaired),
	}
}

func convertTags(tags []controller.ProbeTag) []workercontracts.TagElement {
	converted := make([]workercontracts.TagElement, len(tags))
	for index, tag := range tags {
		converted[index] = workercontracts.TagElement{
			Name:  workercontracts.Name(tag.Name),
			Value: tag.Value,
		}
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

package controller

import "context"

type MediaProbeReader interface {
	Probe(context.Context, string) (ProbeEvidence, error)
}

type Rational struct {
	Numerator   int64
	Denominator int64
}

type ProbeTag struct {
	Name  string
	Value string
}

type ProbeEvidence struct {
	Format   ProbeFormat
	Streams  []ProbeStream
	Programs []ProbeProgram
	Chapters []ProbeChapter
}

type ProbeFormat struct {
	Names        []string
	LongName     *string
	StreamCount  *int64
	ProgramCount *int64
	StartTimeMS  *int64
	DurationMS   *int64
	SizeBytes    *int64
	BitRateBPS   *int64
	ProbeScore   *int64
	Tags         []ProbeTag
}

type ProbeStreamKind string

const (
	ProbeStreamVideo      ProbeStreamKind = "video"
	ProbeStreamAudio      ProbeStreamKind = "audio"
	ProbeStreamSubtitle   ProbeStreamKind = "subtitle"
	ProbeStreamData       ProbeStreamKind = "data"
	ProbeStreamAttachment ProbeStreamKind = "attachment"
	ProbeStreamOther      ProbeStreamKind = "other"
)

type ProbeStream struct {
	Index         int64
	Kind          *ProbeStreamKind
	CodecName     *string
	CodecLongName *string
	Profile       *string
	CodecTag      *string
	Width         *int64
	Height        *int64
	PixelFormat   *string
	SampleFormat  *string
	SampleRateHz  *int64
	Channels      *int64
	ChannelLayout *string
	FrameRate     *Rational
	AverageRate   *Rational
	TimeBase      *Rational
	StartTicks    *int64
	StartTimeMS   *int64
	DurationTicks *int64
	DurationMS    *int64
	BitRateBPS    *int64
	FrameCount    *int64
	Disposition   *ProbeDisposition
	Tags          []ProbeTag
}

type ProbeDisposition struct {
	Default         *bool
	Forced          *bool
	HearingImpaired *bool
	VisualImpaired  *bool
}

type ProbeProgram struct {
	ID            int64
	Number        *int64
	StreamCount   *int64
	PMTPID        *int64
	PCRPID        *int64
	StreamIndexes []int64
	Tags          []ProbeTag
}

type ProbeChapter struct {
	ID          int64
	TimeBase    *Rational
	StartTicks  *int64
	StartTimeMS *int64
	EndTicks    *int64
	EndTimeMS   *int64
	Tags        []ProbeTag
}

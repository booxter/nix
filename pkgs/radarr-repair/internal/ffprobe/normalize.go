package ffprobe

import (
	"fmt"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

// Keep selected tag values within the repair protocol's safe-text bound.
const maxTagValueRunes = 512

func Normalize(document Document) (controller.ProbeEvidence, error) {
	if err := validateDocument(document); err != nil {
		return controller.ProbeEvidence{}, fmt.Errorf("validate ffprobe document: %w", err)
	}

	format, err := normalizeFormat(*document.Format)
	if err != nil {
		return controller.ProbeEvidence{}, fmt.Errorf("normalize format: %w", err)
	}
	evidence := controller.ProbeEvidence{
		Format:   format,
		Streams:  make([]controller.ProbeStream, len(document.Streams)),
		Programs: make([]controller.ProbeProgram, len(document.Programs)),
		Chapters: make([]controller.ProbeChapter, len(document.Chapters)),
	}
	for index, stream := range document.Streams {
		normalized, normalizeErr := normalizeStream(stream)
		if normalizeErr != nil {
			return controller.ProbeEvidence{}, fmt.Errorf("normalize stream %d: %w", *stream.Index, normalizeErr)
		}
		evidence.Streams[index] = normalized
	}
	for index, program := range document.Programs {
		normalized, normalizeErr := normalizeProgram(program)
		if normalizeErr != nil {
			return controller.ProbeEvidence{}, fmt.Errorf("normalize program %d: %w", *program.ID, normalizeErr)
		}
		evidence.Programs[index] = normalized
	}
	for index, chapter := range document.Chapters {
		normalized, normalizeErr := normalizeChapter(chapter)
		if normalizeErr != nil {
			return controller.ProbeEvidence{}, fmt.Errorf("normalize chapter %d: %w", *chapter.ID, normalizeErr)
		}
		evidence.Chapters[index] = normalized
	}
	return evidence, nil
}

func normalizeFormat(format Format) (controller.ProbeFormat, error) {
	names, err := normalizeFormatNames(format.Name)
	if err != nil {
		return controller.ProbeFormat{}, err
	}
	streamCount, err := optionalNonNegative("stream count", format.StreamCount)
	if err != nil {
		return controller.ProbeFormat{}, err
	}
	programCount, err := optionalNonNegative("program count", format.ProgramCount)
	if err != nil {
		return controller.ProbeFormat{}, err
	}
	startTime, err := parseOptionalMilliseconds("start time", format.StartTime, true)
	if err != nil {
		return controller.ProbeFormat{}, err
	}
	duration, err := parseOptionalMilliseconds("duration", format.Duration, false)
	if err != nil {
		return controller.ProbeFormat{}, err
	}
	size, err := parseOptionalInteger("size", format.Size, positive)
	if err != nil {
		return controller.ProbeFormat{}, err
	}
	bitRate, err := parseOptionalInteger("bit rate", format.BitRate, nonNegative)
	if err != nil {
		return controller.ProbeFormat{}, err
	}
	probeScore, err := optionalNonNegative("probe score", format.ProbeScore)
	if err != nil {
		return controller.ProbeFormat{}, err
	}
	tags, err := normalizeTags(format.Tags)
	if err != nil {
		return controller.ProbeFormat{}, err
	}
	return controller.ProbeFormat{
		Names:        names,
		LongName:     copyString(format.LongName),
		StreamCount:  streamCount,
		ProgramCount: programCount,
		StartTimeMS:  startTime,
		DurationMS:   duration,
		SizeBytes:    size,
		BitRateBPS:   bitRate,
		ProbeScore:   probeScore,
		Tags:         tags,
	}, nil
}

func normalizeStream(stream Stream) (controller.ProbeStream, error) {
	kind, err := normalizeStreamKind(stream.CodecType)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	width, err := optionalPositive("width", stream.Width)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	height, err := optionalPositive("height", stream.Height)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	sampleRate, err := parseOptionalInteger("sample rate", stream.SampleRate, positive)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	channels, err := optionalPositive("channels", stream.Channels)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	frameRate, err := parseOptionalRational("frame rate", stream.FrameRate)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	averageRate, err := parseOptionalRational("average frame rate", stream.AverageRate)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	timeBase, err := parseOptionalRational("time base", stream.TimeBase)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	durationTicks, err := optionalNonNegative("duration ticks", stream.DurationTS)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	startTime, err := parseOptionalMilliseconds("start time", stream.StartTime, true)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	duration, err := parseOptionalMilliseconds("duration", stream.Duration, false)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	bitRate, err := parseOptionalInteger("bit rate", stream.BitRate, nonNegative)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	frameCount, err := parseOptionalInteger("frame count", stream.FrameCount, nonNegative)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	disposition, err := normalizeDisposition(stream.Disposition)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	tags, err := normalizeTags(stream.Tags)
	if err != nil {
		return controller.ProbeStream{}, err
	}
	return controller.ProbeStream{
		Index:         *stream.Index,
		Kind:          kind,
		CodecName:     copyString(stream.CodecName),
		CodecLongName: copyString(stream.CodecLongName),
		Profile:       copyString(stream.Profile),
		CodecTag:      copyString(stream.CodecTagString),
		Width:         width,
		Height:        height,
		PixelFormat:   copyString(stream.PixelFormat),
		SampleFormat:  copyString(stream.SampleFormat),
		SampleRateHz:  sampleRate,
		Channels:      channels,
		ChannelLayout: copyString(stream.ChannelLayout),
		FrameRate:     frameRate,
		AverageRate:   averageRate,
		TimeBase:      timeBase,
		StartTicks:    copyInt64(stream.StartPTS),
		StartTimeMS:   startTime,
		DurationTicks: durationTicks,
		DurationMS:    duration,
		BitRateBPS:    bitRate,
		FrameCount:    frameCount,
		Disposition:   disposition,
		Tags:          tags,
	}, nil
}

func normalizeProgram(program Program) (controller.ProbeProgram, error) {
	if *program.ID < 0 {
		return controller.ProbeProgram{}, fmt.Errorf("program ID is negative: %d", *program.ID)
	}
	number, err := optionalNonNegative("program number", program.Number)
	if err != nil {
		return controller.ProbeProgram{}, err
	}
	streamCount, err := optionalNonNegative("stream count", program.StreamCount)
	if err != nil {
		return controller.ProbeProgram{}, err
	}
	pmtPID, err := optionalNonNegative("PMT PID", program.PMTPID)
	if err != nil {
		return controller.ProbeProgram{}, err
	}
	pcrPID, err := optionalNonNegative("PCR PID", program.PCRPID)
	if err != nil {
		return controller.ProbeProgram{}, err
	}
	tags, err := normalizeTags(program.Tags)
	if err != nil {
		return controller.ProbeProgram{}, err
	}
	streamIndexes := make([]int64, len(program.Streams))
	for index, stream := range program.Streams {
		streamIndexes[index] = *stream.Index
	}
	return controller.ProbeProgram{
		ID:            *program.ID,
		Number:        number,
		StreamCount:   streamCount,
		PMTPID:        pmtPID,
		PCRPID:        pcrPID,
		StreamIndexes: streamIndexes,
		Tags:          tags,
	}, nil
}

func normalizeChapter(chapter Chapter) (controller.ProbeChapter, error) {
	if *chapter.ID < 0 {
		return controller.ProbeChapter{}, fmt.Errorf("chapter ID is negative: %d", *chapter.ID)
	}
	timeBase, err := parseOptionalRational("time base", chapter.TimeBase)
	if err != nil {
		return controller.ProbeChapter{}, err
	}
	startTime, err := parseOptionalMilliseconds("start time", chapter.StartTime, true)
	if err != nil {
		return controller.ProbeChapter{}, err
	}
	endTime, err := parseOptionalMilliseconds("end time", chapter.EndTime, true)
	if err != nil {
		return controller.ProbeChapter{}, err
	}
	if chapter.Start != nil && chapter.End != nil && *chapter.End < *chapter.Start {
		return controller.ProbeChapter{}, fmt.Errorf("end tick precedes start tick")
	}
	if startTime != nil && endTime != nil && *endTime < *startTime {
		return controller.ProbeChapter{}, fmt.Errorf("end time precedes start time")
	}
	tags, err := normalizeTags(chapter.Tags)
	if err != nil {
		return controller.ProbeChapter{}, err
	}
	return controller.ProbeChapter{
		ID:          *chapter.ID,
		TimeBase:    timeBase,
		StartTicks:  copyInt64(chapter.Start),
		StartTimeMS: startTime,
		EndTicks:    copyInt64(chapter.End),
		EndTimeMS:   endTime,
		Tags:        tags,
	}, nil
}

func normalizeFormatNames(value *string) ([]string, error) {
	if value == nil || *value == "N/A" {
		return nil, nil
	}
	parts := strings.Split(*value, ",")
	seen := make(map[string]struct{}, len(parts))
	for _, part := range parts {
		if part == "" || strings.TrimSpace(part) != part {
			return nil, fmt.Errorf("invalid format name %q", part)
		}
		if _, exists := seen[part]; exists {
			return nil, fmt.Errorf("duplicate format name %q", part)
		}
		seen[part] = struct{}{}
	}
	return parts, nil
}

func normalizeStreamKind(value *string) (*controller.ProbeStreamKind, error) {
	if value == nil || *value == "N/A" {
		return nil, nil
	}
	if *value == "" || strings.TrimSpace(*value) != *value {
		return nil, fmt.Errorf("invalid stream kind %q", *value)
	}
	var kind controller.ProbeStreamKind
	switch *value {
	case "video":
		kind = controller.ProbeStreamVideo
	case "audio":
		kind = controller.ProbeStreamAudio
	case "subtitle":
		kind = controller.ProbeStreamSubtitle
	case "data":
		kind = controller.ProbeStreamData
	case "attachment":
		kind = controller.ProbeStreamAttachment
	default:
		kind = controller.ProbeStreamOther
	}
	return &kind, nil
}

func normalizeDisposition(value *Disposition) (*controller.ProbeDisposition, error) {
	if value == nil {
		return nil, nil
	}
	defaultValue, err := optionalBoolean("default disposition", value.Default)
	if err != nil {
		return nil, err
	}
	forced, err := optionalBoolean("forced disposition", value.Forced)
	if err != nil {
		return nil, err
	}
	hearingImpaired, err := optionalBoolean("hearing-impaired disposition", value.HearingImpaired)
	if err != nil {
		return nil, err
	}
	visualImpaired, err := optionalBoolean("visual-impaired disposition", value.VisualImpaired)
	if err != nil {
		return nil, err
	}
	return &controller.ProbeDisposition{
		Default:         defaultValue,
		Forced:          forced,
		HearingImpaired: hearingImpaired,
		VisualImpaired:  visualImpaired,
	}, nil
}

func normalizeTags(tags *Tags) ([]controller.ProbeTag, error) {
	if tags == nil {
		return nil, nil
	}
	values := []struct {
		name  string
		value *string
	}{
		{name: "creation_time", value: tags.CreationTime},
		{name: "encoder", value: tags.Encoder},
		{name: "handler_name", value: tags.HandlerName},
		{name: "language", value: tags.Language},
		{name: "service_name", value: tags.ServiceName},
		{name: "service_provider", value: tags.ServiceProvider},
		{name: "title", value: tags.Title},
	}
	normalized := make([]controller.ProbeTag, 0, len(values))
	for _, item := range values {
		if item.value == nil {
			continue
		}
		if err := validateTagValue(*item.value); err != nil {
			return nil, fmt.Errorf("tag %q: %w", item.name, err)
		}
		normalized = append(normalized, controller.ProbeTag{
			Name:  item.name,
			Value: *item.value,
		})
	}
	sort.Slice(normalized, func(left, right int) bool {
		return normalized[left].Name < normalized[right].Name
	})
	return normalized, nil
}

func validateTagValue(value string) error {
	if !utf8.ValidString(value) {
		return fmt.Errorf("invalid UTF-8")
	}
	if utf8.RuneCountInString(value) > maxTagValueRunes {
		return fmt.Errorf("value exceeds %d characters", maxTagValueRunes)
	}
	for _, character := range value {
		if character <= 0x1f || character == 0x7f {
			return fmt.Errorf("value contains control characters")
		}
	}
	return nil
}

type integerConstraint func(int64) bool

func parseOptionalInteger(
	name string,
	value *string,
	constraint integerConstraint,
) (*int64, error) {
	if value == nil || *value == "N/A" {
		return nil, nil
	}
	if strings.TrimSpace(*value) != *value {
		return nil, fmt.Errorf("invalid %s %q", name, *value)
	}
	parsed, err := strconv.ParseInt(*value, 10, 64)
	if err != nil || !constraint(parsed) {
		return nil, fmt.Errorf("invalid %s %q", name, *value)
	}
	return &parsed, nil
}

func parseOptionalMilliseconds(name string, value *string, allowNegative bool) (*int64, error) {
	if value == nil || *value == "N/A" {
		return nil, nil
	}
	if !decimalString(*value) {
		return nil, fmt.Errorf("invalid %s %q", name, *value)
	}
	rational, ok := new(big.Rat).SetString(*value)
	if !ok || (!allowNegative && rational.Sign() < 0) {
		return nil, fmt.Errorf("invalid %s %q", name, *value)
	}
	rational.Mul(rational, big.NewRat(1000, 1))
	rounded, ok := roundRational(rational)
	if !ok {
		return nil, fmt.Errorf("%s %q overflows milliseconds", name, *value)
	}
	return &rounded, nil
}

func parseOptionalRational(name string, value *string) (*controller.Rational, error) {
	if value == nil || *value == "N/A" || *value == "0/0" {
		return nil, nil
	}
	parts := strings.Split(*value, "/")
	if len(parts) != 2 || !integerString(parts[0]) || !integerString(parts[1]) {
		return nil, fmt.Errorf("invalid %s %q", name, *value)
	}
	numerator, numeratorOK := new(big.Int).SetString(parts[0], 10)
	denominator, denominatorOK := new(big.Int).SetString(parts[1], 10)
	if !numeratorOK || !denominatorOK || denominator.Sign() == 0 {
		return nil, fmt.Errorf("invalid %s %q", name, *value)
	}
	rational := new(big.Rat).SetFrac(numerator, denominator)
	if !rational.Num().IsInt64() || !rational.Denom().IsInt64() {
		return nil, fmt.Errorf("%s %q overflows rational", name, *value)
	}
	return &controller.Rational{
		Numerator:   rational.Num().Int64(),
		Denominator: rational.Denom().Int64(),
	}, nil
}

func optionalPositive(name string, value *int64) (*int64, error) {
	if value == nil {
		return nil, nil
	}
	if *value <= 0 {
		return nil, fmt.Errorf("invalid %s %d", name, *value)
	}
	return copyInt64(value), nil
}

func optionalNonNegative(name string, value *int64) (*int64, error) {
	if value == nil {
		return nil, nil
	}
	if *value < 0 {
		return nil, fmt.Errorf("invalid %s %d", name, *value)
	}
	return copyInt64(value), nil
}

func optionalBoolean(name string, value *int64) (*bool, error) {
	if value == nil {
		return nil, nil
	}
	switch *value {
	case 0:
		result := false
		return &result, nil
	case 1:
		result := true
		return &result, nil
	default:
		return nil, fmt.Errorf("invalid %s %d", name, *value)
	}
}

func roundRational(value *big.Rat) (int64, bool) {
	quotient := new(big.Int)
	remainder := new(big.Int)
	quotient.QuoRem(value.Num(), value.Denom(), remainder)
	twiceRemainder := new(big.Int).Abs(remainder)
	twiceRemainder.Lsh(twiceRemainder, 1)
	if twiceRemainder.Cmp(value.Denom()) >= 0 {
		if value.Sign() < 0 {
			quotient.Sub(quotient, big.NewInt(1))
		} else {
			quotient.Add(quotient, big.NewInt(1))
		}
	}
	if !quotient.IsInt64() {
		return 0, false
	}
	return quotient.Int64(), true
}

func decimalString(value string) bool {
	if value == "" {
		return false
	}
	start := 0
	if value[0] == '-' || value[0] == '+' {
		start = 1
	}
	if start == len(value) {
		return false
	}
	dotSeen := false
	digitSeen := false
	for _, character := range value[start:] {
		switch {
		case character >= '0' && character <= '9':
			digitSeen = true
		case character == '.' && !dotSeen:
			dotSeen = true
		default:
			return false
		}
	}
	return digitSeen && value[len(value)-1] != '.'
}

func integerString(value string) bool {
	if value == "" {
		return false
	}
	start := 0
	if value[0] == '-' || value[0] == '+' {
		start = 1
	}
	if start == len(value) {
		return false
	}
	for _, character := range value[start:] {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

func positive(value int64) bool {
	return value > 0
}

func nonNegative(value int64) bool {
	return value >= 0
}

func copyString(value *string) *string {
	if value == nil {
		return nil
	}
	result := *value
	return &result
}

func copyInt64(value *int64) *int64 {
	if value == nil {
		return nil
	}
	result := *value
	return &result
}

package ffprobe

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// MaxDocumentBytes caps metadata-only output. The probe command will not
// request packets, frames, or payload data, so reaching this limit is invalid.
const MaxDocumentBytes = 4 << 20

type Document struct {
	Programs     []Program  `json:"programs"`
	StreamGroups []struct{} `json:"stream_groups"`
	Streams      []Stream   `json:"streams"`
	Chapters     []Chapter  `json:"chapters"`
	Format       *Format    `json:"format"`
}

type Format struct {
	StreamCount  *int64  `json:"nb_streams"`
	ProgramCount *int64  `json:"nb_programs"`
	Name         *string `json:"format_name"`
	LongName     *string `json:"format_long_name"`
	StartTime    *string `json:"start_time"`
	Duration     *string `json:"duration"`
	Size         *string `json:"size"`
	BitRate      *string `json:"bit_rate"`
	ProbeScore   *int64  `json:"probe_score"`
	Tags         *Tags   `json:"tags"`
}

type Stream struct {
	Index          *int64       `json:"index"`
	CodecName      *string      `json:"codec_name"`
	CodecLongName  *string      `json:"codec_long_name"`
	Profile        *string      `json:"profile"`
	CodecType      *string      `json:"codec_type"`
	CodecTagString *string      `json:"codec_tag_string"`
	Width          *int64       `json:"width"`
	Height         *int64       `json:"height"`
	PixelFormat    *string      `json:"pix_fmt"`
	SampleFormat   *string      `json:"sample_fmt"`
	SampleRate     *string      `json:"sample_rate"`
	Channels       *int64       `json:"channels"`
	ChannelLayout  *string      `json:"channel_layout"`
	FrameRate      *string      `json:"r_frame_rate"`
	AverageRate    *string      `json:"avg_frame_rate"`
	TimeBase       *string      `json:"time_base"`
	StartPTS       *int64       `json:"start_pts"`
	StartTime      *string      `json:"start_time"`
	DurationTS     *int64       `json:"duration_ts"`
	Duration       *string      `json:"duration"`
	BitRate        *string      `json:"bit_rate"`
	FrameCount     *string      `json:"nb_frames"`
	Disposition    *Disposition `json:"disposition"`
	Tags           *Tags        `json:"tags"`
	// FFprobe emits this section for MPEG-2 even when no side-data fields are
	// requested. Its contents do not contribute to repair decisions.
	SideDataList []json.RawMessage `json:"side_data_list"`
}

type Disposition struct {
	Default         *int64 `json:"default"`
	Forced          *int64 `json:"forced"`
	HearingImpaired *int64 `json:"hearing_impaired"`
	VisualImpaired  *int64 `json:"visual_impaired"`
}

type Program struct {
	ID          *int64          `json:"program_id"`
	Number      *int64          `json:"program_num"`
	StreamCount *int64          `json:"nb_streams"`
	PMTPID      *int64          `json:"pmt_pid"`
	PCRPID      *int64          `json:"pcr_pid"`
	Tags        *Tags           `json:"tags"`
	Streams     []ProgramStream `json:"streams"`
}

// Selecting top-level stream fields also makes ffprobe repeat those fields in
// program streams. Only the index is retained after normalization.
type ProgramStream Stream

type Chapter struct {
	ID        *int64  `json:"id"`
	TimeBase  *string `json:"time_base"`
	Start     *int64  `json:"start"`
	StartTime *string `json:"start_time"`
	End       *int64  `json:"end"`
	EndTime   *string `json:"end_time"`
	Tags      *Tags   `json:"tags"`
}

// Tags is the union of metadata keys requested for formats, streams,
// programs, and chapters. Arbitrary ffprobe tags are intentionally excluded.
type Tags struct {
	Language        *string `json:"language"`
	Title           *string `json:"title"`
	HandlerName     *string `json:"handler_name"`
	Encoder         *string `json:"encoder"`
	CreationTime    *string `json:"creation_time"`
	ServiceName     *string `json:"service_name"`
	ServiceProvider *string `json:"service_provider"`
}

func Decode(data []byte) (Document, error) {
	if len(data) > MaxDocumentBytes {
		return Document{}, fmt.Errorf(
			"ffprobe JSON is %d bytes, limit is %d",
			len(data),
			MaxDocumentBytes,
		)
	}

	var document Document
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&document); err != nil {
		return Document{}, fmt.Errorf("decode ffprobe JSON: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return Document{}, fmt.Errorf("decode ffprobe JSON: multiple JSON values")
		}
		return Document{}, fmt.Errorf("decode ffprobe JSON trailing data: %w", err)
	}
	if err := validateDocument(document); err != nil {
		return Document{}, fmt.Errorf("validate ffprobe JSON: %w", err)
	}
	return document, nil
}

func validateDocument(document Document) error {
	if document.Format == nil {
		return fmt.Errorf("missing format")
	}
	if len(document.StreamGroups) != 0 {
		return fmt.Errorf("stream groups are not supported")
	}

	streamIndexes := make(map[int64]struct{}, len(document.Streams))
	for position, stream := range document.Streams {
		if stream.Index == nil {
			return fmt.Errorf("stream %d is missing its index", position)
		}
		if *stream.Index < 0 {
			return fmt.Errorf("stream %d has negative index %d", position, *stream.Index)
		}
		if _, exists := streamIndexes[*stream.Index]; exists {
			return fmt.Errorf("duplicate stream index %d", *stream.Index)
		}
		streamIndexes[*stream.Index] = struct{}{}
	}

	programIDs := make(map[int64]struct{}, len(document.Programs))
	for position, program := range document.Programs {
		if program.ID == nil {
			return fmt.Errorf("program %d is missing its ID", position)
		}
		if _, exists := programIDs[*program.ID]; exists {
			return fmt.Errorf("duplicate program ID %d", *program.ID)
		}
		programIDs[*program.ID] = struct{}{}

		members := make(map[int64]struct{}, len(program.Streams))
		for memberPosition, stream := range program.Streams {
			if stream.Index == nil {
				return fmt.Errorf(
					"program %d stream %d is missing its index",
					*program.ID,
					memberPosition,
				)
			}
			if _, exists := streamIndexes[*stream.Index]; !exists {
				return fmt.Errorf(
					"program %d references unknown stream index %d",
					*program.ID,
					*stream.Index,
				)
			}
			if _, exists := members[*stream.Index]; exists {
				return fmt.Errorf(
					"program %d repeats stream index %d",
					*program.ID,
					*stream.Index,
				)
			}
			members[*stream.Index] = struct{}{}
		}
	}

	chapterIDs := make(map[int64]struct{}, len(document.Chapters))
	for position, chapter := range document.Chapters {
		if chapter.ID == nil {
			return fmt.Errorf("chapter %d is missing its ID", position)
		}
		if _, exists := chapterIDs[*chapter.ID]; exists {
			return fmt.Errorf("duplicate chapter ID %d", *chapter.ID)
		}
		chapterIDs[*chapter.ID] = struct{}{}
	}
	return nil
}

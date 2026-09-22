// Package dvdvideo reads DVD-Video title metadata from libdvdread via lsdvd.
package dvdvideo

import (
	"bytes"
	"context"
	"encoding/xml"
	"fmt"
	"math"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const maximumOutputBytes = 1 << 20

type Track struct {
	Kind     string
	Codec    string
	Language string
}

type Title struct {
	Number     int
	DurationMS int64
	Chapters   int
	Angles     int
	TitleSet   int
	TitleInSet int
	Tracks     []Track
}

type Identifier interface {
	IdentifyDVD(context.Context, Target) ([]Title, error)
}

type Target struct {
	NavigationPath      string
	ExpectedFingerprint string
}

type Runner struct{ Executable string }

func (runner Runner) IdentifyDVD(ctx context.Context, target Target) ([]Title, error) {
	directory := filepath.Dir(target.NavigationPath)
	if !filepath.IsAbs(runner.Executable) || filepath.Clean(runner.Executable) != runner.Executable ||
		!filepath.IsAbs(target.NavigationPath) || filepath.Clean(target.NavigationPath) != target.NavigationPath ||
		filepath.Base(target.NavigationPath) != "VIDEO_TS.IFO" {
		return nil, fmt.Errorf("lsdvd executable and DVD directory must be absolute and clean")
	}
	var output bytes.Buffer
	command := exec.CommandContext(ctx, runner.Executable, "-x", "-Ox", directory)
	command.Stdout = &limitedWriter{buffer: &output, limit: maximumOutputBytes}
	if err := command.Run(); err != nil {
		return nil, fmt.Errorf("identify DVD titles: %w", err)
	}
	return decodeTitles(output.Bytes())
}

type limitedWriter struct {
	buffer *bytes.Buffer
	limit  int
}

func (writer *limitedWriter) Write(data []byte) (int, error) {
	if len(data) > writer.limit-writer.buffer.Len() {
		return 0, fmt.Errorf("DVD identification exceeds %d bytes", writer.limit)
	}
	return writer.buffer.Write(data)
}

type discXML struct {
	XMLName xml.Name   `xml:"lsdvd"`
	Titles  []titleXML `xml:"track"`
}

type titleXML struct {
	Number     int           `xml:"ix"`
	Length     string        `xml:"length"`
	TitleSet   int           `xml:"vts"`
	TitleInSet int           `xml:"ttn"`
	Angles     int           `xml:"angles"`
	Video      string        `xml:"format"`
	Audio      []audioXML    `xml:"audio"`
	Subtitles  []subtitleXML `xml:"subp"`
	Chapters   []chapterXML  `xml:"chapter"`
}

type audioXML struct {
	Format   string `xml:"format"`
	Language string `xml:"langcode"`
}

type subtitleXML struct {
	Language string `xml:"langcode"`
}

type chapterXML struct {
	Number int `xml:"ix"`
}

func decodeTitles(data []byte) ([]Title, error) {
	var disc discXML
	if err := xml.Unmarshal(data, &disc); err != nil {
		return nil, fmt.Errorf("decode DVD title XML: %w", err)
	}
	if len(disc.Titles) == 0 || len(disc.Titles) > 128 {
		return nil, fmt.Errorf("DVD has an invalid title count")
	}
	titles := make([]Title, 0, len(disc.Titles))
	for index, raw := range disc.Titles {
		durationSeconds, err := strconv.ParseFloat(raw.Length, 64)
		if err != nil || math.IsNaN(durationSeconds) || math.IsInf(durationSeconds, 0) ||
			durationSeconds <= 0 || durationSeconds > 7*24*60*60 ||
			raw.Number != index+1 || raw.TitleSet <= 0 || raw.TitleSet > 99 ||
			raw.TitleInSet <= 0 || raw.TitleInSet > 99 || raw.Angles <= 0 || raw.Angles > 9 ||
			len(raw.Chapters) == 0 || len(raw.Chapters) > 4096 || raw.Video == "" {
			return nil, fmt.Errorf("DVD title %d has invalid metadata", index+1)
		}
		for chapterIndex, chapter := range raw.Chapters {
			if chapter.Number != chapterIndex+1 {
				return nil, fmt.Errorf("DVD title %d has invalid chapters", raw.Number)
			}
		}
		tracks := []Track{{Kind: "video", Codec: "mpeg2video"}}
		for _, audio := range raw.Audio {
			codec, ok := audioCodec(audio.Format)
			if !ok {
				return nil, fmt.Errorf("DVD title %d has unsupported audio codec", raw.Number)
			}
			tracks = append(tracks, Track{Kind: "audio", Codec: codec, Language: language(audio.Language)})
		}
		for _, subtitle := range raw.Subtitles {
			tracks = append(tracks, Track{Kind: "subtitles", Codec: "dvd_subtitle", Language: language(subtitle.Language)})
		}
		if len(tracks) > 32 {
			return nil, fmt.Errorf("DVD title %d has too many tracks", raw.Number)
		}
		titles = append(titles, Title{
			Number: raw.Number, DurationMS: int64(math.Round(durationSeconds * 1000)),
			Chapters: len(raw.Chapters), Angles: raw.Angles,
			TitleSet: raw.TitleSet, TitleInSet: raw.TitleInSet, Tracks: tracks,
		})
	}
	return titles, nil
}

func audioCodec(format string) (string, bool) {
	switch strings.ToLower(format) {
	case "ac3":
		return "ac3", true
	case "dts":
		return "dts", true
	case "mpeg1", "mpeg2":
		return "mp2", true
	case "lpcm":
		return "pcm_dvd", true
	default:
		return "", false
	}
}

func language(code string) string {
	if code == "xx" {
		return ""
	}
	return code
}

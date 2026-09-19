// Package mkvmerge reads Blu-ray playlist metadata from MKVToolNix.
package mkvmerge

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
)

const maximumOutputBytes = 1 << 20

type Track struct {
	Kind     string
	Codec    string
	Language string
}

type Playlist struct {
	DurationMS int64
	Chapters   int
	ClipPaths  []string
	Tracks     []Track
}

type Identifier interface {
	Identify(context.Context, string) (Playlist, error)
}

type Runner struct {
	Executable string
}

func (runner Runner) Identify(ctx context.Context, path string) (Playlist, error) {
	if !cleanAbsolute(runner.Executable) || !cleanAbsolute(path) {
		return Playlist{}, fmt.Errorf("mkvmerge and playlist paths must be absolute and clean")
	}

	var output bytes.Buffer
	command := exec.CommandContext(
		ctx, runner.Executable, "--identification-format", "json", "--identify", path,
	)
	command.Stdout = &limitedWriter{buffer: &output, limit: maximumOutputBytes}
	if err := command.Run(); err != nil {
		return Playlist{}, fmt.Errorf("identify Blu-ray playlist: %w", err)
	}
	return decodePlaylist(output.Bytes())
}

func cleanAbsolute(path string) bool {
	return path != "" && filepath.IsAbs(path) && filepath.Clean(path) == path
}

type limitedWriter struct {
	buffer *bytes.Buffer
	limit  int
}

func (writer *limitedWriter) Write(data []byte) (int, error) {
	if len(data) > writer.limit-writer.buffer.Len() {
		return 0, fmt.Errorf("mkvmerge identification exceeds %d bytes", writer.limit)
	}
	return writer.buffer.Write(data)
}

type identification struct {
	Container struct {
		Recognized bool `json:"recognized"`
		Supported  bool `json:"supported"`
		Properties struct {
			Playlist   bool     `json:"playlist"`
			DurationNS int64    `json:"playlist_duration"`
			Chapters   int      `json:"playlist_chapters"`
			ClipPaths  []string `json:"playlist_file"`
		} `json:"properties"`
	} `json:"container"`
	Errors   []string `json:"errors"`
	Warnings []string `json:"warnings"`
	Tracks   []struct {
		Kind       string `json:"type"`
		Codec      string `json:"codec"`
		Properties struct {
			Language string `json:"language"`
		} `json:"properties"`
	} `json:"tracks"`
}

func decodePlaylist(data []byte) (Playlist, error) {
	var identified identification
	if err := json.Unmarshal(data, &identified); err != nil {
		return Playlist{}, fmt.Errorf("decode mkvmerge identification: %w", err)
	}

	properties := identified.Container.Properties
	if !identified.Container.Recognized || !identified.Container.Supported ||
		!properties.Playlist || len(identified.Errors) != 0 || len(identified.Warnings) != 0 ||
		properties.DurationNS <= 0 || properties.DurationNS > 7*24*60*60*1_000_000_000 ||
		properties.Chapters < 0 || properties.Chapters > 4096 ||
		len(properties.ClipPaths) == 0 || len(properties.ClipPaths) > 1024 {
		return Playlist{}, fmt.Errorf("mkvmerge did not identify a complete Blu-ray playlist")
	}

	playlist := Playlist{
		DurationMS: properties.DurationNS / 1_000_000,
		Chapters:   properties.Chapters,
		ClipPaths:  properties.ClipPaths,
	}
	hasVideo := false
	for _, track := range identified.Tracks {
		if track.Kind != "video" && track.Kind != "audio" && track.Kind != "subtitles" {
			continue
		}
		if track.Codec == "" {
			return Playlist{}, fmt.Errorf("mkvmerge identified a track without a codec")
		}
		hasVideo = hasVideo || track.Kind == "video"
		playlist.Tracks = append(playlist.Tracks, Track{
			Kind: track.Kind, Codec: track.Codec, Language: track.Properties.Language,
		})
	}
	if !hasVideo {
		return Playlist{}, fmt.Errorf("mkvmerge playlist has no video track")
	}
	return playlist, nil
}

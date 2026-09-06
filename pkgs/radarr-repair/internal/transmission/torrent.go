package transmission

import (
	"context"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

var torrentFields = []string{
	"hash_string",
	"name",
	"status",
	"percent_done",
	"left_until_done",
	"is_finished",
	"download_dir",
	"labels",
	"date_created",
	"added_date",
	"done_date",
	"total_size",
	"files",
	"file_stats",
	"tracker_stats",
}

// Existing tagged Go clients target Transmission's deprecated pre-4.1 RPC
// envelope. The available 4.1-specific client has no tagged release and needs
// a newer Go toolchain, so this package keeps its one read operation local.
func (client *Client) FindTorrent(
	ctx context.Context,
	downloadID string,
) (controller.TransmissionTorrent, bool, error) {
	if downloadID == "" || strings.TrimSpace(downloadID) != downloadID ||
		strings.ContainsRune(downloadID, '\x00') {
		return controller.TransmissionTorrent{}, false, fmt.Errorf("Transmission torrent ID is invalid")
	}

	result, err := client.rpc(ctx, "torrent_get", torrentGetRequest{
		IDs:    []string{downloadID},
		Fields: torrentFields,
	})
	if err != nil {
		return controller.TransmissionTorrent{}, false, err
	}
	var response torrentGetResponse
	if err := decodeOneJSON(result, &response); err != nil {
		return controller.TransmissionTorrent{}, false, fmt.Errorf("decode Transmission torrent result: %w", err)
	}
	if response.Torrents == nil {
		return controller.TransmissionTorrent{}, false, fmt.Errorf("Transmission torrent result is missing torrents")
	}
	switch len(response.Torrents) {
	case 0:
		return controller.TransmissionTorrent{}, false, nil
	case 1:
		torrent, err := mapTorrent(response.Torrents[0])
		if err != nil {
			return controller.TransmissionTorrent{}, false, err
		}
		return torrent, true, nil
	default:
		return controller.TransmissionTorrent{}, false, fmt.Errorf(
			"Transmission returned %d torrents for one ID",
			len(response.Torrents),
		)
	}
}

type torrentGetResponse struct {
	Torrents []*torrentResponse `json:"torrents"`
}

type torrentResponse struct {
	HashString    *string                    `json:"hash_string"`
	Name          *string                    `json:"name"`
	Status        *int                       `json:"status"`
	PercentDone   *float64                   `json:"percent_done"`
	LeftUntilDone *int64                     `json:"left_until_done"`
	IsFinished    *bool                      `json:"is_finished"`
	DownloadDir   *string                    `json:"download_dir"`
	Labels        []string                   `json:"labels"`
	DateCreated   *int64                     `json:"date_created"`
	AddedDate     *int64                     `json:"added_date"`
	DoneDate      *int64                     `json:"done_date"`
	TotalSize     *int64                     `json:"total_size"`
	Files         []*torrentFileResponse     `json:"files"`
	FileStats     []*torrentFileStatResponse `json:"file_stats"`
	TrackerStats  []*torrentTrackerResponse  `json:"tracker_stats"`
}

type torrentFileResponse struct {
	Name           *string `json:"name"`
	Length         *int64  `json:"length"`
	BytesCompleted *int64  `json:"bytes_completed"`
}

type torrentFileStatResponse struct {
	BytesCompleted *int64 `json:"bytes_completed"`
	Wanted         *bool  `json:"wanted"`
	Priority       *int   `json:"priority"`
}

type torrentTrackerResponse struct {
	Host string `json:"host"`
}

func mapTorrent(raw *torrentResponse) (controller.TransmissionTorrent, error) {
	if raw == nil {
		return controller.TransmissionTorrent{}, fmt.Errorf("Transmission torrent is null")
	}
	if raw.HashString == nil || strings.TrimSpace(*raw.HashString) == "" {
		return controller.TransmissionTorrent{}, fmt.Errorf("Transmission torrent hash is missing")
	}
	if raw.Name == nil || strings.TrimSpace(*raw.Name) == "" {
		return controller.TransmissionTorrent{}, fmt.Errorf("Transmission torrent name is missing")
	}
	if raw.Status == nil || raw.PercentDone == nil || raw.LeftUntilDone == nil ||
		raw.IsFinished == nil || raw.DownloadDir == nil || raw.TotalSize == nil {
		return controller.TransmissionTorrent{}, fmt.Errorf("Transmission torrent is missing required fields")
	}
	if !finiteFraction(*raw.PercentDone) {
		return controller.TransmissionTorrent{}, fmt.Errorf("Transmission torrent completion is invalid")
	}
	if *raw.LeftUntilDone < 0 || *raw.TotalSize < 0 {
		return controller.TransmissionTorrent{}, fmt.Errorf("Transmission torrent sizes must not be negative")
	}
	if *raw.DownloadDir == "" || strings.ContainsRune(*raw.DownloadDir, '\x00') {
		return controller.TransmissionTorrent{}, fmt.Errorf("Transmission download directory is invalid")
	}
	if raw.Labels == nil || raw.Files == nil || raw.FileStats == nil || raw.TrackerStats == nil {
		return controller.TransmissionTorrent{}, fmt.Errorf("Transmission torrent is missing required collections")
	}
	if len(raw.Files) != len(raw.FileStats) {
		return controller.TransmissionTorrent{}, fmt.Errorf(
			"Transmission returned %d files and %d file stats",
			len(raw.Files),
			len(raw.FileStats),
		)
	}

	files, totalSize, err := mapFiles(raw.Files, raw.FileStats)
	if err != nil {
		return controller.TransmissionTorrent{}, err
	}
	if totalSize != *raw.TotalSize {
		return controller.TransmissionTorrent{}, fmt.Errorf(
			"Transmission file sizes total %d but torrent reports %d",
			totalSize,
			*raw.TotalSize,
		)
	}
	labels, err := validateLabels(raw.Labels)
	if err != nil {
		return controller.TransmissionTorrent{}, err
	}
	trackerHosts, err := normalizeTrackerHosts(raw.TrackerStats)
	if err != nil {
		return controller.TransmissionTorrent{}, err
	}
	createdAt, err := requiredUnixTime("creation", raw.DateCreated)
	if err != nil {
		return controller.TransmissionTorrent{}, err
	}
	addedAt, err := requiredUnixTime("added", raw.AddedDate)
	if err != nil {
		return controller.TransmissionTorrent{}, err
	}
	completedAt, err := requiredUnixTime("completion", raw.DoneDate)
	if err != nil {
		return controller.TransmissionTorrent{}, err
	}

	return controller.TransmissionTorrent{
		Hash:              *raw.HashString,
		Name:              *raw.Name,
		Status:            controller.TransmissionStatus(*raw.Status),
		PercentDone:       *raw.PercentDone,
		LeftUntilDone:     *raw.LeftUntilDone,
		Finished:          *raw.IsFinished,
		DownloadDirectory: *raw.DownloadDir,
		Labels:            labels,
		CreatedAt:         createdAt,
		AddedAt:           addedAt,
		CompletedAt:       completedAt,
		TotalSizeBytes:    *raw.TotalSize,
		Files:             files,
		TrackerHosts:      trackerHosts,
	}, nil
}

func mapFiles(
	files []*torrentFileResponse,
	stats []*torrentFileStatResponse,
) ([]controller.TransmissionFile, int64, error) {
	result := make([]controller.TransmissionFile, len(files))
	seenNames := make(map[string]struct{}, len(files))
	var totalSize int64
	for index := range files {
		file := files[index]
		stat := stats[index]
		if file == nil || stat == nil {
			return nil, 0, fmt.Errorf("Transmission file %d or its stats are null", index)
		}
		if file.Name == nil || *file.Name == "" || strings.ContainsRune(*file.Name, '\x00') {
			return nil, 0, fmt.Errorf("Transmission file %d name is invalid", index)
		}
		if _, exists := seenNames[*file.Name]; exists {
			return nil, 0, fmt.Errorf("Transmission contains duplicate file name %q", *file.Name)
		}
		seenNames[*file.Name] = struct{}{}
		if file.Length == nil || file.BytesCompleted == nil || stat.BytesCompleted == nil ||
			stat.Wanted == nil || stat.Priority == nil {
			return nil, 0, fmt.Errorf("Transmission file %d is missing required fields", index)
		}
		if *file.Length < 0 || *file.BytesCompleted < 0 || *file.BytesCompleted > *file.Length {
			return nil, 0, fmt.Errorf("Transmission file %d sizes are invalid", index)
		}
		if *file.BytesCompleted != *stat.BytesCompleted {
			return nil, 0, fmt.Errorf("Transmission file %d completion values disagree", index)
		}
		if totalSize > math.MaxInt64-*file.Length {
			return nil, 0, fmt.Errorf("Transmission file sizes overflow")
		}
		totalSize += *file.Length
		result[index] = controller.TransmissionFile{
			Index:          index,
			Name:           *file.Name,
			LengthBytes:    *file.Length,
			BytesCompleted: *file.BytesCompleted,
			Wanted:         *stat.Wanted,
			Priority:       *stat.Priority,
		}
	}
	return result, totalSize, nil
}

func validateLabels(raw []string) ([]string, error) {
	labels := append([]string(nil), raw...)
	seen := make(map[string]struct{}, len(labels))
	for index, label := range labels {
		if strings.TrimSpace(label) == "" || strings.ContainsRune(label, '\x00') {
			return nil, fmt.Errorf("Transmission label %d is invalid", index)
		}
		if _, exists := seen[label]; exists {
			return nil, fmt.Errorf("Transmission contains duplicate label %q", label)
		}
		seen[label] = struct{}{}
	}
	return labels, nil
}

func requiredUnixTime(field string, raw *int64) (*time.Time, error) {
	if raw == nil {
		return nil, fmt.Errorf("Transmission torrent %s time is missing", field)
	}
	timestamp, err := unixTime(*raw)
	if err != nil {
		return nil, fmt.Errorf("Transmission torrent %s time: %w", field, err)
	}
	return timestamp, nil
}

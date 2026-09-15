package transmission

import (
	"context"
	"fmt"
	"math"
	"path/filepath"
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
}

// Existing tagged Go clients target Transmission's deprecated pre-4.1 RPC
// envelope. The available 4.1-specific client has no tagged release and needs
// a newer Go toolchain, so this package keeps its one read operation local.
func (client *Client) FindDownload(
	ctx context.Context,
	downloadID string,
) (controller.Download, bool, error) {
	if downloadID == "" || strings.TrimSpace(downloadID) != downloadID ||
		strings.ContainsRune(downloadID, '\x00') || !validInfoHash(downloadID) {
		return controller.Download{}, false, fmt.Errorf("Transmission torrent ID is invalid")
	}

	result, err := client.rpc(ctx, "torrent_get", torrentGetRequest{
		IDs:    []string{downloadID},
		Fields: torrentFields,
	})
	if err != nil {
		return controller.Download{}, false, err
	}
	var response torrentGetResponse
	if err := decodeOneJSON(result, &response); err != nil {
		return controller.Download{}, false, fmt.Errorf("decode Transmission torrent result: %w", err)
	}
	if response.Torrents == nil {
		return controller.Download{}, false, fmt.Errorf("Transmission torrent result is missing torrents")
	}
	switch len(response.Torrents) {
	case 0:
		return controller.Download{}, false, nil
	case 1:
		torrent, err := mapTorrent(response.Torrents[0])
		if err != nil {
			return controller.Download{}, false, err
		}
		return torrent, true, nil
	default:
		return controller.Download{}, false, fmt.Errorf(
			"Transmission returned %d torrents for one ID",
			len(response.Torrents),
		)
	}
}

func validInfoHash(value string) bool {
	if len(value) != 40 {
		return false
	}
	for _, character := range value {
		if !((character >= '0' && character <= '9') ||
			(character >= 'a' && character <= 'f') ||
			(character >= 'A' && character <= 'F')) {
			return false
		}
	}
	return true
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

func mapTorrent(raw *torrentResponse) (controller.Download, error) {
	if raw == nil {
		return controller.Download{}, fmt.Errorf("Transmission torrent is null")
	}
	if raw.HashString == nil || strings.TrimSpace(*raw.HashString) == "" {
		return controller.Download{}, fmt.Errorf("Transmission torrent hash is missing")
	}
	if raw.Name == nil || strings.TrimSpace(*raw.Name) == "" {
		return controller.Download{}, fmt.Errorf("Transmission torrent name is missing")
	}
	if raw.Status == nil || raw.PercentDone == nil || raw.LeftUntilDone == nil ||
		raw.IsFinished == nil || raw.DownloadDir == nil || raw.TotalSize == nil {
		return controller.Download{}, fmt.Errorf("Transmission torrent is missing required fields")
	}
	if !finiteFraction(*raw.PercentDone) {
		return controller.Download{}, fmt.Errorf("Transmission torrent completion is invalid")
	}
	if *raw.LeftUntilDone < 0 || *raw.TotalSize < 0 {
		return controller.Download{}, fmt.Errorf("Transmission torrent sizes must not be negative")
	}
	if *raw.DownloadDir == "" || strings.ContainsRune(*raw.DownloadDir, '\x00') {
		return controller.Download{}, fmt.Errorf("Transmission download directory is invalid")
	}
	if raw.Labels == nil || raw.Files == nil || raw.FileStats == nil {
		return controller.Download{}, fmt.Errorf("Transmission torrent is missing required collections")
	}
	if len(raw.Files) != len(raw.FileStats) {
		return controller.Download{}, fmt.Errorf(
			"Transmission returned %d files and %d file stats",
			len(raw.Files),
			len(raw.FileStats),
		)
	}

	files, totalSize, err := mapFiles(raw.Files, raw.FileStats)
	if err != nil {
		return controller.Download{}, err
	}
	if totalSize != *raw.TotalSize {
		return controller.Download{}, fmt.Errorf(
			"Transmission file sizes total %d but torrent reports %d",
			totalSize,
			*raw.TotalSize,
		)
	}
	labels, err := validateLabels(raw.Labels)
	if err != nil {
		return controller.Download{}, err
	}
	createdAt, err := requiredUnixTime("creation", raw.DateCreated)
	if err != nil {
		return controller.Download{}, err
	}
	addedAt, err := requiredUnixTime("added", raw.AddedDate)
	if err != nil {
		return controller.Download{}, err
	}
	completedAt, err := requiredUnixTime("completion", raw.DoneDate)
	if err != nil {
		return controller.Download{}, err
	}

	for index := range files {
		files[index].Path = filepath.Join(*raw.DownloadDir, filepath.FromSlash(files[index].Path))
	}
	return controller.Download{
		Client:           controller.DownloadClientTransmission,
		SourceType:       controller.DownloadSourceTorrent,
		ID:               strings.ToLower(*raw.HashString),
		IDComparison:     controller.DownloadIDASCIIInsensitive,
		Name:             *raw.Name,
		Stable:           stableTorrentStatus(*raw.Status),
		Complete:         *raw.PercentDone == 1 && *raw.LeftUntilDone == 0,
		OutputPath:       transmissionDownloadRoot(*raw.DownloadDir, *raw.Name),
		Labels:           labels,
		CreatedAt:        createdAt,
		AddedAt:          addedAt,
		CompletedAt:      completedAt,
		TotalSizeBytes:   *raw.TotalSize,
		ContentOwnership: controller.DownloadContentManifest,
		Files:            files,
	}, nil
}

func mapFiles(
	files []*torrentFileResponse,
	stats []*torrentFileStatResponse,
) ([]controller.DownloadFile, int64, error) {
	result := make([]controller.DownloadFile, len(files))
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
		result[index] = controller.DownloadFile{
			Index:          index,
			HasIndex:       true,
			Path:           *file.Name,
			LengthBytes:    *file.Length,
			BytesCompleted: *file.BytesCompleted,
			Selected:       *stat.Wanted,
		}
	}
	return result, totalSize, nil
}

func stableTorrentStatus(status int) bool {
	return status == 0 || status == 5 || status == 6
}

func transmissionDownloadRoot(directory, name string) string {
	if directory == "" || strings.TrimSpace(directory) != directory ||
		strings.ContainsRune(directory, '\x00') || !filepath.IsAbs(directory) ||
		filepath.Clean(directory) != directory {
		return ""
	}
	if name == "" || strings.ContainsRune(name, '\x00') ||
		strings.ContainsRune(name, filepath.Separator) || filepath.Base(name) != name ||
		name == "." || name == ".." {
		return ""
	}
	// Radarr replaces colons when it derives Transmission's queue output path.
	return filepath.Join(directory, strings.ReplaceAll(name, ":", "_"))
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

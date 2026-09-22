package sabnzbd

import (
	"context"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

var _ controller.DownloadReader = (*Client)(nil)

func (client *Client) FindDownload(
	ctx context.Context,
	downloadID string,
) (controller.Download, bool, error) {
	if !validDownloadID(downloadID) {
		return controller.Download{}, false, fmt.Errorf("SABnzbd download ID is invalid")
	}
	var response historyResponse
	err := client.get(ctx, url.Values{
		"mode":    {"history"},
		"start":   {"0"},
		"limit":   {"2"},
		"nzo_ids": {downloadID},
	}, &response)
	if err != nil {
		return controller.Download{}, false, err
	}
	if response.History == nil || response.History.Slots == nil {
		return controller.Download{}, false, fmt.Errorf("SABnzbd history response is incomplete")
	}
	switch len(response.History.Slots) {
	case 0:
		return controller.Download{}, false, nil
	case 1:
		download, mapErr := mapHistorySlot(response.History.Slots[0])
		if mapErr != nil {
			return controller.Download{}, false, mapErr
		}
		if download.ID != downloadID {
			return controller.Download{}, false, fmt.Errorf("SABnzbd returned a different download ID")
		}
		return download, true, nil
	default:
		return controller.Download{}, false, fmt.Errorf(
			"SABnzbd returned %d history records for one ID",
			len(response.History.Slots),
		)
	}
}

type historyResponse struct {
	History *historyResult `json:"history"`
}

type historyResult struct {
	Slots []*historySlot `json:"slots"`
}

type historySlot struct {
	NZOID     *string `json:"nzo_id"`
	Name      *string `json:"name"`
	Status    *string `json:"status"`
	Storage   *string `json:"storage"`
	Loaded    *bool   `json:"loaded"`
	Completed *int64  `json:"completed"`
	TimeAdded *int64  `json:"time_added"`
	Bytes     *int64  `json:"bytes"`
	Category  *string `json:"category"`
}

func mapHistorySlot(raw *historySlot) (controller.Download, error) {
	if raw == nil {
		return controller.Download{}, fmt.Errorf("SABnzbd history record is null")
	}
	if raw.NZOID == nil || !validDownloadID(*raw.NZOID) ||
		raw.Name == nil || strings.TrimSpace(*raw.Name) == "" ||
		raw.Status == nil || raw.Storage == nil || raw.Loaded == nil ||
		raw.Completed == nil || raw.TimeAdded == nil || raw.Bytes == nil || raw.Category == nil {
		return controller.Download{}, fmt.Errorf("SABnzbd history record is missing required fields")
	}
	if *raw.Bytes < 0 {
		return controller.Download{}, fmt.Errorf("SABnzbd history size must not be negative")
	}
	completedAt, err := unixTime("completion", *raw.Completed)
	if err != nil {
		return controller.Download{}, err
	}
	addedAt, err := unixTime("added", *raw.TimeAdded)
	if err != nil {
		return controller.Download{}, err
	}
	outputPath, err := radarrOutputPath(*raw.Storage, *raw.Name)
	if err != nil {
		return controller.Download{}, err
	}
	labels := []string{}
	if *raw.Category != "" {
		labels = append(labels, *raw.Category)
	}
	complete := strings.EqualFold(*raw.Status, "completed")
	return controller.Download{
		Client:           controller.DownloadClientSABnzbd,
		SourceType:       controller.DownloadSourceUsenet,
		ID:               *raw.NZOID,
		IDComparison:     controller.DownloadIDExact,
		Name:             *raw.Name,
		Stable:           complete && !*raw.Loaded,
		Complete:         complete,
		OutputPath:       outputPath,
		Labels:           labels,
		AddedAt:          addedAt,
		CompletedAt:      completedAt,
		TotalSizeBytes:   *raw.Bytes,
		ContentOwnership: controller.DownloadContentOutputTree,
		Files:            []controller.DownloadFile{},
	}, nil
}

func validDownloadID(value string) bool {
	if value == "" || len(value) > 256 || strings.TrimSpace(value) != value {
		return false
	}
	for _, character := range value {
		if character == 0 || unicode.IsControl(character) {
			return false
		}
	}
	return true
}

func unixTime(field string, value int64) (*time.Time, error) {
	if value <= 0 {
		return nil, fmt.Errorf("SABnzbd %s time is invalid", field)
	}
	timestamp := time.Unix(value, 0).UTC()
	return &timestamp, nil
}

func radarrOutputPath(storage, name string) (string, error) {
	if storage == "" || strings.ContainsRune(storage, '\x00') ||
		!filepath.IsAbs(storage) || filepath.Clean(storage) != storage {
		return "", fmt.Errorf("SABnzbd storage path is invalid")
	}
	result := storage
	for current := storage; ; current = filepath.Dir(current) {
		if filepath.Base(current) == name {
			result = current
			break
		}
		parent := filepath.Dir(current)
		if parent == current {
			break
		}
	}
	if filepath.Dir(result) == result {
		return "", fmt.Errorf("SABnzbd output path is invalid")
	}
	return result, nil
}

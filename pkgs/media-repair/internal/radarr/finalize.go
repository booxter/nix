package radarr

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
)

type FinalizationReader interface {
	ReadMovie(context.Context, int64) (controller.RadarrMovie, error)
}

func FinalizationCandidates(
	ctx context.Context,
	reader FinalizationReader,
	records []controller.RadarrQueueRecord,
) ([]queuefinalize.Entry, error) {
	if reader == nil {
		return nil, fmt.Errorf("Radarr finalization reader is required")
	}
	complete := make(map[int64]bool)
	checked := make(map[int64]bool)
	result := make([]queuefinalize.Entry, 0)
	for _, record := range records {
		entry := FinalizationEntry(record)
		if !entry.Eligible() || record.MovieID == nil {
			continue
		}
		if !checked[*record.MovieID] {
			movie, readErr := reader.ReadMovie(ctx, *record.MovieID)
			if readErr != nil {
				return nil, fmt.Errorf(
					"inspect Radarr movie %d for finalization: %w", *record.MovieID, readErr,
				)
			}
			complete[*record.MovieID] = movie.HasFile
			checked[*record.MovieID] = true
		}
		if complete[*record.MovieID] {
			result = append(result, entry)
		}
	}
	return result, nil
}

func FinalizationEntry(record controller.RadarrQueueRecord) queuefinalize.Entry {
	subjectID := int64(0)
	if record.MovieID != nil {
		subjectID = *record.MovieID
	}
	return queuefinalize.Entry{
		Protocol: string(record.Protocol), DownloadClient: record.DownloadClient,
		QueueID: record.ID, DownloadID: record.DownloadID, SubjectID: subjectID,
		Status: string(record.Status), TrackedDownloadStatus: string(record.TrackedDownloadStatus),
	}
}

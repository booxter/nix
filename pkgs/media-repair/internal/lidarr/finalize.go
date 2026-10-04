package lidarr

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
)

type FinalizationReader interface {
	ReadQueue(context.Context) ([]QueueRecord, error)
	AlbumIdentityReader
	ReadAlbum(context.Context, int64) (Album, error)
	ReadReleaseTracks(context.Context, int64, int64) ([]Track, error)
}

type FinalizationQueueReader interface {
	ReadQueue(context.Context) ([]QueueRecord, error)
	AlbumIdentityReader
}

func ReadFinalizationEntries(
	ctx context.Context,
	reader FinalizationQueueReader,
) ([]queuefinalize.Entry, error) {
	records, err := readFinalizationQueue(ctx, reader)
	if err != nil {
		return nil, err
	}
	entries := make([]queuefinalize.Entry, len(records))
	for index, record := range records {
		entries[index] = FinalizationEntry(record)
	}
	return entries, nil
}

func FinalizationCandidates(
	ctx context.Context,
	reader FinalizationReader,
) ([]queuefinalize.Entry, error) {
	if reader == nil {
		return nil, fmt.Errorf("Lidarr finalization reader is required")
	}
	records, err := readFinalizationQueue(ctx, reader)
	if err != nil {
		return nil, fmt.Errorf("read Lidarr queue for finalization: %w", err)
	}
	complete := make(map[int64]bool)
	checked := make(map[int64]bool)
	result := make([]queuefinalize.Entry, 0)
	for _, record := range records {
		entry := FinalizationEntry(record)
		if !entry.Eligible() || record.AlbumID == nil || record.ArtistID == nil {
			continue
		}
		if !checked[*record.AlbumID] {
			complete[*record.AlbumID], err = monitoredReleaseComplete(ctx, reader, *record.AlbumID)
			if err != nil {
				return nil, fmt.Errorf("inspect Lidarr album %d for finalization: %w", *record.AlbumID, err)
			}
			checked[*record.AlbumID] = true
		}
		if complete[*record.AlbumID] {
			result = append(result, entry)
		}
	}
	return result, nil
}

func readFinalizationQueue(
	ctx context.Context,
	reader FinalizationQueueReader,
) ([]QueueRecord, error) {
	records, err := reader.ReadQueue(ctx)
	if err != nil {
		return nil, err
	}
	for index, record := range records {
		if record.AlbumID != nil && record.ArtistID != nil {
			continue
		}
		if record.ID <= 0 || record.DownloadID == "" || record.Status != "completed" ||
			record.TrackedDownloadStatus != "warning" {
			continue
		}
		recovered, recoverErr := RecoverQueueIdentity(ctx, reader, record)
		if recoverErr != nil {
			return nil, fmt.Errorf("recover Lidarr queue %d identity: %w", record.ID, recoverErr)
		}
		records[index] = recovered
	}
	return records, nil
}

func FinalizationEntry(record QueueRecord) queuefinalize.Entry {
	subjectID := int64(0)
	if record.AlbumID != nil && record.ArtistID != nil {
		subjectID = *record.AlbumID
	}
	return queuefinalize.Entry{
		QueueID: record.ID, DownloadID: record.DownloadID, SubjectID: subjectID,
		Status: string(record.Status), TrackedDownloadStatus: string(record.TrackedDownloadStatus),
	}
}

func monitoredReleaseComplete(
	ctx context.Context,
	reader FinalizationReader,
	albumID int64,
) (bool, error) {
	album, err := reader.ReadAlbum(ctx, albumID)
	if err != nil {
		return false, err
	}
	if !album.Monitored {
		return false, nil
	}
	var monitored *Release
	for index := range album.Releases {
		release := &album.Releases[index]
		if !release.Monitored {
			continue
		}
		if monitored != nil {
			return false, nil
		}
		monitored = release
	}
	if monitored == nil {
		return false, nil
	}
	tracks, err := reader.ReadReleaseTracks(ctx, album.ID, monitored.ID)
	if err != nil {
		return false, err
	}
	if len(tracks) != monitored.TrackCount {
		return false, nil
	}
	for _, track := range tracks {
		if !track.HasFile || track.TrackFileID <= 0 {
			return false, nil
		}
	}
	return true, nil
}

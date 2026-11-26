package inspection

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

// ResolvedEntry pairs a Radarr queue entry with what we found in the download client.
type ResolvedEntry struct {
	record          controller.RadarrQueueRecord
	sourceSupported bool
	source          *controller.DownloadCorrelation
}

func (entry ResolvedEntry) canLookUpDownload() bool {
	return entry.sourceSupported && entry.record.HasDownloadID()
}

// Resolve looks up unfinished downloads too, so a single report can explain
// both why Radarr is waiting and whether the download client still lists the download.
func (inspector *Inspector) Resolve(ctx context.Context, record controller.RadarrQueueRecord) (ResolvedEntry, error) {
	entry := ResolvedEntry{
		record:          record,
		sourceSupported: inspector.dependencies.Downloads.Supports(record.Protocol, record.DownloadClient),
	}
	if !entry.canLookUpDownload() {
		return entry, nil
	}
	ctx, cancel := context.WithTimeout(ctx, inspector.dependencies.CollectionTimeout)
	defer cancel()
	return inspector.lookUpMovieAndDownload(ctx, entry)
}

// lookUpMovieAndDownload identifies the movie and checks whether the download
// client has a matching entry. A successful lookup can return an empty result.
func (inspector *Inspector) lookUpMovieAndDownload(ctx context.Context, entry ResolvedEntry) (ResolvedEntry, error) {
	if entry.record.MovieID == nil {
		// Radarr's history can name the movie even when the queue entry does not.
		movieID, found, err := inspector.dependencies.Radarr.RecoverMovieID(ctx, entry.record.DownloadID)
		if err != nil {
			return ResolvedEntry{}, fmt.Errorf("recover Radarr movie identity: %w", err)
		}
		if found {
			entry.record.MovieID = &movieID
		}
	}

	download, found, err := inspector.dependencies.Downloads.Resolve(ctx, entry.record)
	if err != nil {
		return ResolvedEntry{}, fmt.Errorf("read download: %w", err)
	}
	if found {
		source := controller.CorrelateDownload(entry.record, download)
		entry.source = &source
	}
	return entry, nil
}

// QueueFindings reports why the queue entry should be skipped, even if its download was found.
func (entry ResolvedEntry) QueueFindings() []string {
	var findings []string
	for _, reason := range entry.record.Assess(entry.sourceSupported).RejectionReasons {
		findings = append(findings, string(reason))
	}
	return findings
}

// SourceFindings explains what is missing or inconsistent about the movie and its download.
func (entry ResolvedEntry) SourceFindings() []string {
	var findings []string
	if entry.record.MovieID == nil || *entry.record.MovieID <= 0 {
		findings = append(findings, "missing_movie_id")
	}
	if entry.source == nil {
		// Report a missing download only if we could actually ask its client.
		if entry.canLookUpDownload() {
			findings = append(findings, "download_not_found")
		}
		return findings
	}
	for _, reason := range entry.source.RejectionReasons {
		findings = append(findings, string(reason))
	}
	return findings
}

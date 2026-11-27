package lidarrrepair

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/pipeline"
)

// A download can disappear between scans. The previous record identifies
// the saved workspace for this entry if we need to inspect its files again.
type albumInspection struct {
	*EvidenceCollector
	previous *Record
}

var collection = pipeline.CollectionFlow[
	albumInspection,
	lidarr.QueueRecord,
	lidarr.QueueRecord,
	Evidence,
]{
	Resolve: albumInspection.recoverQueueIdentity,
	Validators: pipeline.Validators[lidarr.QueueRecord]{
		downloadFindings,
		albumIdentityFindings,
	},
	Collect: albumInspection.collectEvidence,
}

type CollectionResult = pipeline.Result[Evidence]

func (collector *EvidenceCollector) Inspect(
	ctx context.Context,
	queue lidarr.QueueRecord,
	previous *Record,
) CollectionResult {
	inspection := albumInspection{EvidenceCollector: collector, previous: previous}
	return collection.Inspect(ctx, inspection, queue)
}

// Lidarr can omit the album or artist from a queue entry. Look them up in
// download history only when the entry is otherwise ready for repair.
func (inspection albumInspection) recoverQueueIdentity(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (lidarr.QueueRecord, error) {
	if len(downloadFindings(queue)) > 0 {
		return queue, nil
	}

	recovered, err := lidarr.RecoverQueueIdentity(ctx, inspection.lidarr, queue)
	if err != nil {
		return queue, fmt.Errorf("recover Lidarr album identity: %w", err)
	}
	return recovered, nil
}

func albumIdentityFindings(queue lidarr.QueueRecord) []string {
	var findings []string
	if queue.AlbumID == nil {
		findings = append(findings, "missing_album_id")
	}
	if queue.ArtistID == nil {
		findings = append(findings, "missing_artist_id")
	}
	return findings
}

func downloadFindings(queue lidarr.QueueRecord) []string {
	var findings []string
	if queue.OutputPath == "" {
		findings = append(findings, "missing_output_path")
	}
	if queue.DownloadID == "" {
		findings = append(findings, "missing_download_id")
	}
	if queue.Status != "completed" {
		findings = append(findings, "incomplete_download")
	}
	if queue.TrackedDownloadStatus != "warning" {
		findings = append(findings, "unsupported_queue_state")
	}
	return findings
}

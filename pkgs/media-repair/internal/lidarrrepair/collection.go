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
	Resolve:    albumInspection.recoverQueueIdentity,
	Validators: pipeline.Validators[lidarr.QueueRecord]{queueFindings},
	Collect:    albumInspection.collectEvidence,
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
	if !downloadReady(queue) {
		return queue, nil
	}

	recovered, err := lidarr.RecoverQueueIdentity(ctx, inspection.lidarr, queue)
	if err != nil {
		return queue, fmt.Errorf("recover Lidarr album identity: %w", err)
	}
	return recovered, nil
}

func queueFindings(queue lidarr.QueueRecord) []string {
	if queue.AlbumID == nil || queue.ArtistID == nil || !downloadReady(queue) {
		return []string{"Lidarr queue item is not eligible for repair"}
	}
	return nil
}

func downloadReady(queue lidarr.QueueRecord) bool {
	return queue.OutputPath != "" && queue.DownloadID != "" &&
		queue.Status == "completed" && queue.TrackedDownloadStatus == "warning"
}

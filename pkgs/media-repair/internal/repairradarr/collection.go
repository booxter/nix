package repairradarr

import (
	"context"

	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/pipeline"
)

// Queue scans and pre-import rechecks use the same steps for each entry.
var collection = pipeline.CollectionFlow[
	*Inspector,
	controller.RadarrQueueRecord,
	resolvedEntry,
	casebuilder.Assembly,
]{
	Resolve: (*Inspector).resolve,
	Validators: pipeline.Validators[resolvedEntry]{
		resolvedEntry.queueFindings,
		resolvedEntry.sourceFindings,
	},
	Collect: (*Inspector).collect,
}

type CollectionResult = pipeline.Result[casebuilder.Assembly]

// CollectQueue scans the Radarr queue once. For each entry it finishes, the caller
// receives a case, the reasons the entry was skipped, or an inspection error.
func CollectQueue(
	ctx context.Context,
	queue controller.RadarrQueueReader,
	inspector *Inspector,
	report func(controller.RadarrQueueRecord, CollectionResult) error,
) error {
	return pipeline.ScanQueue(ctx, queue.ReadQueue, inspector.Inspect, report)
}

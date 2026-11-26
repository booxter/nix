package repairradarr

import (
	"context"

	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/pipeline"
)

type collectionClients struct {
	controller.RadarrQueueReader
	*Inspector
}

// Every scan follows these steps. CollectQueue supplies its clients when the scan starts.
var collection = pipeline.CollectionFlow[
	collectionClients,
	controller.RadarrQueueRecord,
	resolvedEntry,
	casebuilder.Assembly,
]{
	Discover: collectionClients.ReadQueue,
	Resolve:  collectionClients.resolve,
	Validators: pipeline.Validators[resolvedEntry]{
		resolvedEntry.queueFindings,
		resolvedEntry.sourceFindings,
	},
	Collect: collectionClients.collect,
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
	return collection.Run(ctx, collectionClients{queue, inspector}, report)
}

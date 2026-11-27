package repairradarr

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/executioncheck"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/repair"
)

type authorizedRepair struct {
	source    casebuilder.Assembly
	operation executioncheck.Authorization
}

// authorize binds the saved decision to files Repairr has just inspected.
// The planner may have taken minutes, or the operator may have paused repairs.
func (adapter *Adapter) authorize(ctx context.Context, job jobs.Job, plan json.RawMessage) (authorizedRepair, error) {
	var planned Evidence
	if err := json.Unmarshal(job.Evidence, &planned); err != nil {
		return authorizedRepair{}, err
	}
	decision, err := contracts.DecodeDecision(plan)
	if err != nil {
		return authorizedRepair{}, err
	}

	fresh, err := adapter.readQueuedCase(ctx, job.QueueKey())
	if err != nil {
		return authorizedRepair{}, err
	}
	queue := fresh.LocalSnapshot.Observation.Correlation.Radarr
	if selectedFileChanged(planned.Snapshot, fresh.LocalSnapshot, decision) {
		return authorizedRepair{}, &repair.BlockedError{Reason: "selected file changed after planning", Code: jobs.OutcomeEvidenceChanged}
	}
	if err := adapter.CheckImportState(string(queue.TrackedDownloadState), job.StableSince); err != nil {
		return authorizedRepair{}, err
	}
	fresh, matches := fresh.ForSavedPlan(planned.Assembly())
	if queue.DownloadID != job.DownloadID || !matches {
		return authorizedRepair{}, &repair.BlockedError{Reason: "source or queue identity changed; collect a new plan"}
	}

	policy := decisionpolicy.RuntimePolicy{MaximumDifferenceMS: job.RuntimeToleranceMS}
	operation, reason := executioncheck.Authorize(fresh, decision, policy)
	if reason != "" {
		blocked := &repair.BlockedError{Reason: "decision rejected: " + string(reason)}
		if reason == executioncheck.RuntimeMismatch {
			blocked.Code = jobs.OutcomeRuntimeMismatch
			blocked.Question = Question(fresh.Request, string(reason), nil)
		}
		return authorizedRepair{}, blocked
	}
	if reason, unsafe := executioncheck.ReplacementRejection(fresh, operation); unsafe {
		return authorizedRepair{}, &repair.BlockedError{Reason: string(reason)}
	}
	return authorizedRepair{source: fresh, operation: operation}, nil
}

func (adapter *Adapter) readQueuedCase(ctx context.Context, key jobs.QueueKey) (casebuilder.Assembly, error) {
	entry, err := repair.ReadQueueEntry(ctx, key, adapter.Client.ReadQueue, func(entry controller.RadarrQueueRecord) jobs.QueueKey {
		return jobs.QueueKey{QueueID: entry.ID, DownloadID: entry.DownloadID}
	})
	if err != nil {
		return casebuilder.Assembly{}, err
	}

	// Limit the entire recheck, including the download lookup and file reads.
	if adapter.Inspector == nil {
		return casebuilder.Assembly{}, fmt.Errorf("inspector is not configured")
	}
	recheckCtx, cancel := controller.WithCollectionTimeout(ctx, adapter.Inspector.dependencies.CollectionTimeout)
	defer cancel()
	result := adapter.Inspector.Inspect(recheckCtx, entry)
	if err := ctx.Err(); err != nil {
		return casebuilder.Assembly{}, repair.RetryableRead(err)
	}
	if result.Err != nil {
		return casebuilder.Assembly{}, repair.RetryableRead(result.Err)
	}
	if err := repair.CheckEligibility(result.Findings, jobs.OutcomeOther); err != nil {
		return casebuilder.Assembly{}, err
	}
	return *result.Case, nil
}

// A file ID follows its path. Compare the file at that path with the one
// offered to the planner so a same-size replacement has a specific stop reason.
func selectedFileChanged(planned, fresh casebuilder.LocalSnapshot, decision contracts.RepairDecisionV3) bool {
	selection := decision.ManualImportFile
	if selection == nil {
		return false
	}
	binding, found := planned.ManualImportBindings[selection.CapabilityID]
	if !found || string(binding.FileID) != selection.FileID {
		return false
	}
	for _, file := range fresh.Observation.Inventory.Files {
		if file.ID == binding.FileID {
			return file.Fingerprint != binding.ExpectedFingerprint
		}
	}
	return true
}

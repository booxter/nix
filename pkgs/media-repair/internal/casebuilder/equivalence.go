package casebuilder

import (
	"reflect"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/controller"
)

// ForSavedPlan checks fresh evidence against the case the planner actually saw.
// Radarr giving up its pending import changes the case hash even if every file
// and import option stayed the same.
func (fresh Assembly) ForSavedPlan(planned Assembly) (Assembly, bool) {
	comparison := fresh
	if planned.Request.Radarr.Failure.TrackedDownloadState == "importPending" &&
		fresh.Request.Radarr.Failure.TrackedDownloadState == "importBlocked" &&
		fresh.LocalSnapshot.Observation.Correlation.Radarr.TrackedDownloadState == "importBlocked" {
		comparison.Request.Radarr.Failure.TrackedDownloadState = "importPending"
		comparison.LocalSnapshot.Observation.Correlation.Radarr.TrackedDownloadState = "importPending"
		id, err := contracts.CalculateCaseID(comparison.Request)
		if err != nil {
			return Assembly{}, false
		}
		comparison.Request.CaseID = id
		comparison.LocalSnapshot.CaseID = id
	}
	if !sameCaseState(planned, comparison) {
		return Assembly{}, false
	}

	// The decision refers to the original request. Run its safety checks with
	// the current queue record, file bindings and manual-import rejections.
	fresh.Request = comparison.Request
	fresh.LocalSnapshot.CaseID = comparison.Request.CaseID
	return fresh, true
}

func sameCaseState(left, right Assembly) bool {
	leftRequest := left.Request
	rightRequest := right.Request
	leftRequest.ObservedAt = rightRequest.ObservedAt

	leftSnapshot := left.LocalSnapshot
	rightSnapshot := right.LocalSnapshot
	leftSnapshot.Observation.ObservedAt = rightSnapshot.Observation.ObservedAt
	leftSnapshot = withoutManualImportRejectionCodes(leftSnapshot)
	rightSnapshot = withoutManualImportRejectionCodes(rightSnapshot)

	return reflect.DeepEqual(leftRequest, rightRequest) &&
		reflect.DeepEqual(leftSnapshot, rightSnapshot)
}

// Reason codes drive policy from the fresh Radarr response. The accompanying
// messages remain part of case identity and preserve older stored observations.
func withoutManualImportRejectionCodes(snapshot LocalSnapshot) LocalSnapshot {
	imports := make([]controller.RadarrManualImport, len(snapshot.Observation.ManualImports))
	copy(imports, snapshot.Observation.ManualImports)
	for importIndex := range imports {
		rejections := make(
			[]controller.RadarrManualImportRejection,
			len(imports[importIndex].Rejections),
		)
		copy(rejections, imports[importIndex].Rejections)
		for rejectionIndex := range rejections {
			rejections[rejectionIndex].Code = ""
		}
		imports[importIndex].Rejections = rejections
	}
	snapshot.Observation.ManualImports = imports
	return snapshot
}

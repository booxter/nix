package casebuilder

import (
	"reflect"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

// SameCaseState compares the typed request and controller snapshot while
// allowing only their collection timestamps to differ.
func SameCaseState(left, right Assembly) bool {
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

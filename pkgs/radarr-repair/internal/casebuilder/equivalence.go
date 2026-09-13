package casebuilder

import "reflect"

// SameCaseState compares the typed request and controller snapshot while
// allowing only their collection timestamps to differ.
func SameCaseState(left, right Assembly) bool {
	leftRequest := left.Request
	rightRequest := right.Request
	leftRequest.ObservedAt = rightRequest.ObservedAt

	leftSnapshot := left.LocalSnapshot
	rightSnapshot := right.LocalSnapshot
	leftSnapshot.Observation.ObservedAt = rightSnapshot.Observation.ObservedAt

	return reflect.DeepEqual(leftRequest, rightRequest) &&
		reflect.DeepEqual(leftSnapshot, rightSnapshot)
}

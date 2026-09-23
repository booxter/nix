package planning

import "errors"

type FailureKind string

const (
	FailureUnavailable   FailureKind = "planner_unavailable"
	FailureTimeout       FailureKind = "planner_timeout"
	FailureHTTP          FailureKind = "planner_http_error"
	FailureInvalidResult FailureKind = "planner_invalid_result"
	FailureUnexpected    FailureKind = "planner_unexpected_error"
)

type Failure struct {
	Kind       FailureKind `json:"kind"`
	StatusCode int         `json:"status_code,omitempty"`
}

type FailureSource interface {
	PlanningFailure() Failure
}

type InvalidResultError struct {
	Err error
}

func (failure *InvalidResultError) Error() string {
	return "planner returned an invalid result: " + failure.Err.Error()
}

func (failure *InvalidResultError) Unwrap() error {
	return failure.Err
}

func (*InvalidResultError) PlanningFailure() Failure {
	return Failure{Kind: FailureInvalidResult}
}

func ClassifyFailure(err error) Failure {
	var source FailureSource
	if errors.As(err, &source) {
		return source.PlanningFailure()
	}
	return Failure{Kind: FailureUnexpected}
}

func ValidFailure(failure Failure) bool {
	switch failure.Kind {
	case FailureHTTP:
		return failure.StatusCode >= 100 && failure.StatusCode <= 599
	case FailureUnavailable,
		FailureTimeout,
		FailureInvalidResult,
		FailureUnexpected:
		return failure.StatusCode == 0
	default:
		return false
	}
}

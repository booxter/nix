package review

import (
	"time"

	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
)

func NewReconsideration(
	request reconsideration.Request,
	result reconsideration.Result,
	decided bool,
	prior Decision,
) Reconsideration {
	state := ReconsiderationPending
	if decided {
		state = ReconsiderationDecided
	} else if result.Outcome.Failure != nil {
		state = ReconsiderationFailed
	}
	description := Reconsideration{
		RequestID: request.RequestID, Guidance: request.Guidance,
		PolicyOverrides: request.PolicyOverrides, CreatedAt: request.CreatedAt,
		State: state, PriorDecision: prior, Attempts: result.Outcome.Attempts,
		AttemptedAt: optionalTime(result.Outcome.AttemptedAt),
		RetryAfter:  optionalTimePointer(result.Outcome.RetryAfter),
	}
	if result.Outcome.Failure != nil {
		description.Failure = string(result.Outcome.Failure.Kind)
	}
	return description
}

func optionalTime(value time.Time) *time.Time {
	if value.IsZero() {
		return nil
	}
	value = value.UTC()
	return &value
}

func optionalTimePointer(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	return optionalTime(*value)
}

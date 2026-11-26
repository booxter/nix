package repair

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

// Each service supplies two steps. The type returned by Authorize is the
// input to PrepareImport, so a movie can carry a remux plan and an album
// can carry the selected tracks.
type ImportSteps[Approved any] struct {
	Authorize     func(context.Context, jobs.Job, json.RawMessage) (Approved, error)
	PrepareImport func(context.Context, jobs.Attempt, Approved) (PreparedImport, error)
}

// The engine can run either service's steps without knowing its media types.
type ImportFlow interface {
	prepare(context.Context, jobs.Job, jobs.Attempt) (PreparedImport, error)
}

func (steps ImportSteps[Approved]) prepare(ctx context.Context, job jobs.Job, attempt jobs.Attempt) (PreparedImport, error) {
	approved, err := steps.Authorize(ctx, job, attempt.Plan)
	if err != nil {
		return PreparedImport{}, err
	}
	return steps.PrepareImport(ctx, attempt, approved)
}

// A queued download can become ineligible while its plan waits to run.
// Keep the inspection findings as the operator-visible reason for stopping.
func CheckEligibility(findings []string, code jobs.Outcome) error {
	if len(findings) == 0 {
		return nil
	}
	return &BlockedError{Reason: strings.Join(findings, ", "), Code: code}
}

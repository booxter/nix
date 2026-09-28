package review

import (
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
)

func TestNewReconsiderationDescribesFailedAttempt(t *testing.T) {
	t.Parallel()
	createdAt := time.Date(2026, 9, 27, 1, 0, 0, 0, time.UTC)
	attemptedAt := createdAt.Add(time.Minute)
	retryAfter := attemptedAt.Add(5 * time.Minute)
	request, err := reconsideration.NewRequest(
		reconsideration.ServiceRadarr,
		"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"Check the release-specific runtime.",
		createdAt,
	)
	if err != nil {
		t.Fatal(err)
	}
	description := NewReconsideration(request, reconsideration.Result{
		Outcome: planning.StoredResult{
			Attempts: 2, AttemptedAt: attemptedAt, RetryAfter: &retryAfter,
			Failure: &planning.Failure{Kind: planning.FailureTimeout},
		},
	}, false, Decision{Action: "no_repair", Explanation: "Runtime mismatch."})
	if description.State != ReconsiderationFailed || description.Attempts != 2 ||
		description.AttemptedAt == nil || !description.AttemptedAt.Equal(attemptedAt) ||
		description.RetryAfter == nil || !description.RetryAfter.Equal(retryAfter) ||
		description.Failure != string(planning.FailureTimeout) {
		t.Fatalf("reconsideration = %#v", description)
	}
}

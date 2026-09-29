package review

import (
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/queueaction"
)

func ApplyQueueRemovals(snapshot *Snapshot, processed []queueaction.Processed) error {
	if snapshot == nil {
		return fmt.Errorf("review snapshot is required")
	}
	byCase := make(map[string]queueaction.Processed, len(processed))
	for _, action := range processed {
		if queueaction.Service(snapshot.Service) != action.Request.Service {
			return fmt.Errorf("queue removal belongs to another service")
		}
		byCase[action.Request.CaseID] = action
	}
	for index := range snapshot.Current {
		action, found := byCase[snapshot.Current[index].CaseID]
		if !found {
			continue
		}
		attemptedAt := action.Result.AttemptedAt.UTC()
		snapshot.Current[index].QueueRemoval = &QueueRemoval{
			RequestID: action.Request.RequestID, CreatedAt: action.Request.CreatedAt,
			State: action.Result.State, Attempts: action.Result.Attempts,
			AttemptedAt: optionalRemovalTime(attemptedAt), Outcome: action.Result.Outcome,
			Failure: action.Result.Failure,
		}
	}
	return snapshot.Validate()
}

func optionalRemovalTime(value time.Time) *time.Time {
	if value.IsZero() {
		return nil
	}
	return &value
}

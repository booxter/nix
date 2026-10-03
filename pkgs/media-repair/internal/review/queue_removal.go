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
	current := snapshot.Current[:0]
	for index := range snapshot.Current {
		item := snapshot.Current[index]
		action, found := byCase[item.CaseID]
		if !found {
			current = append(current, item)
			continue
		}
		attemptedAt := action.Result.AttemptedAt.UTC()
		item.QueueRemoval = &QueueRemoval{
			RequestID: action.Request.RequestID, CreatedAt: action.Request.CreatedAt,
			State: action.Result.State, Attempts: action.Result.Attempts,
			AttemptedAt: optionalRemovalTime(attemptedAt), Outcome: action.Result.Outcome,
			Failure: action.Result.Failure,
		}
		if action.Result.State == queueaction.StateCompleted {
			item.State = StateNoLongerQueued
			item.NoLongerQueuedAt = &attemptedAt
			snapshot.History = append(snapshot.History, item)
			continue
		}
		current = append(current, item)
	}
	snapshot.Current = current
	return snapshot.Validate()
}

func optionalRemovalTime(value time.Time) *time.Time {
	if value.IsZero() {
		return nil
	}
	return &value
}

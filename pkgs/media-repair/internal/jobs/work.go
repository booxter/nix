package jobs

import (
	"context"
	"time"
)

// Interrupted preparations and submitted imports still need reconciliation
// after their queue entry disappears. Only new work depends on queue presence.
func (store *Store) DueRepairs(ctx context.Context, service Service, now time.Time) ([]Job, error) {
	var result []Job
	err := store.db.WithContext(ctx).Where("service = ?", service).
		Where(`state IN ? OR (
			in_queue AND state IN ? AND COALESCE(collection_error, '') = ''
			AND COALESCE(json_array_length(findings), 0) = 0
			AND COALESCE(pending_action, '') <> ? AND (retry_at IS NULL OR retry_at <= ?)
			AND (state = ? OR length(evidence) > 0)
		)`, []State{Running, Importing}, []State{Observed, Ready}, Delete, now.UTC(), Ready).
		Order("id").Find(&result).Error
	return result, err
}

func (store *Store) DueRemovals(ctx context.Context, service Service, now time.Time) ([]int64, error) {
	var ids []int64
	err := store.db.WithContext(ctx).Model(&Job{}).
		Where("service = ? AND pending_action = ?", service, Delete).
		Where("retry_at IS NULL OR retry_at <= ?", now.UTC()).
		Order("id").Pluck("id", &ids).Error
	return ids, err
}

type StateCount struct {
	State State
	Count int64
}

func (store *Store) QueueCounts(ctx context.Context, service Service) ([]StateCount, error) {
	var counts []StateCount
	err := store.db.WithContext(ctx).Model(&Job{}).
		Select("state, count(*) AS count").Where("service = ?", service).
		Where("in_queue OR state = ?", Importing).Group("state").Scan(&counts).Error
	return counts, err
}

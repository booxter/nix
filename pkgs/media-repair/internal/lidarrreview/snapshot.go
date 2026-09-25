package lidarrreview

import (
	"fmt"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/review"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

func Snapshot(report lidarrrepair.Report, generatedAt time.Time) (review.Snapshot, error) {
	snapshot := review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceLidarr,
		GeneratedAt: generatedAt.UTC(), Current: make([]review.Item, 0, len(report.Reviews)),
	}
	for _, observed := range report.Reviews {
		item, err := item(observed, snapshot.GeneratedAt)
		if err != nil {
			return review.Snapshot{}, fmt.Errorf("Lidarr queue %d: %w", observed.Queue.ID, err)
		}
		snapshot.Current = append(snapshot.Current, item)
	}
	review.Sort(&snapshot)
	return snapshot, snapshot.Validate()
}

func item(observed lidarrrepair.QueueReview, generatedAt time.Time) (review.Item, error) {
	item := review.Item{
		QueueID: observed.Queue.ID, Title: strings.TrimSpace(observed.Queue.Title),
		QueueStatus:   string(observed.Queue.Status),
		TrackedStatus: string(observed.Queue.TrackedDownloadStatus),
		Protocol:      string(observed.Queue.Protocol), LastSeenAt: generatedAt,
		State: review.StateNotProcessed, Detail: observed.Detail,
	}
	if !observed.Candidate {
		if item.TrackedStatus != "warning" {
			item.State = review.StateActive
		}
		return item, nil
	}
	if observed.Record.QueueID > 0 {
		repairCase, err := lidarrcontracts.DecodeCase(observed.Record.Case)
		if err != nil {
			return review.Item{}, err
		}
		item.CaseID = repairCase.CaseID
		item.SourceFingerprint = observed.Record.SourceFingerprint
		observedAt := repairCase.ObservedAt.UTC()
		item.ObservedAt = &observedAt
		item.Subject = strings.TrimSpace(repairCase.Album.Artist + " — " + repairCase.Album.Title)
	}
	switch observed.Outcome {
	case planningrunner.Deferred:
		item.State = review.StatePlanningDeferred
		item.Detail = "planner retry is deferred"
	case planningrunner.Failed:
		item.State = review.StatePlanningFailed
		if observed.Failure != nil {
			item.Detail = string(observed.Failure.Kind)
		}
	case planningrunner.Decided, planningrunner.AlreadyDecided:
		decision, err := review.ParseDecision(observed.Record.Decision)
		if err != nil {
			return review.Item{}, err
		}
		item.Decision = &decision
		if decision.Action == string(lidarrcontracts.ActionNoRepair) {
			item.State = review.StateReviewed
		} else {
			item.State = review.StateRepairPlanned
		}
		item.Detail = ""
	default:
		item.State = review.StatePlanningFailed
	}
	return item, nil
}

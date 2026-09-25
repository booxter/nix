package radarrreview

import (
	"fmt"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/review"
	shadowrunner "github.com/booxter/nix-config/media-repair/internal/shadow"
)

func Snapshot(report shadowrunner.Report, generatedAt time.Time) (review.Snapshot, error) {
	generatedAt = generatedAt.UTC()
	items := make(map[int64]review.Item, len(report.Queue))
	for _, record := range report.Queue {
		state := review.StateNotProcessed
		detail := "no current repair case"
		if record.TrackedDownloadStatus != "warning" {
			state = review.StateActive
			detail = "queue item is not a completed import warning"
		}
		items[record.ID] = review.Item{
			QueueID: record.ID, Title: strings.TrimSpace(record.Title),
			QueueStatus: string(record.Status), TrackedStatus: string(record.TrackedDownloadStatus),
			Protocol: string(record.Protocol), State: state, Detail: detail, LastSeenAt: generatedAt,
		}
	}
	for _, rejection := range report.Rejections {
		item, found := items[rejection.QueueID]
		if !found {
			continue
		}
		item.State = review.StateNotProcessed
		item.Detail = string(rejection.Reason)
		items[rejection.QueueID] = item
	}
	for _, current := range report.Reviews {
		queue := current.Assembly.LocalSnapshot.Observation.Correlation.Radarr
		item, found := items[queue.ID]
		if !found {
			return review.Snapshot{}, fmt.Errorf("planned case refers to absent queue %d", queue.ID)
		}
		item.CaseID = current.Assembly.Request.CaseID
		item.SourceFingerprint = current.Assembly.Request.CaseID
		observedAt := current.Assembly.Request.ObservedAt.UTC()
		item.ObservedAt = &observedAt
		if movie := current.Assembly.LocalSnapshot.Observation.Movie; movie != nil {
			item.Subject = strings.TrimSpace(fmt.Sprintf("%s (%d)", movie.Title, movie.Year))
		}
		switch current.Outcome {
		case planningrunner.Deferred:
			item.State = review.StatePlanningDeferred
			item.Detail = "planner retry is deferred"
		case planningrunner.Failed:
			item.State = review.StatePlanningFailed
			item.Detail = "evidence collection or planning failed"
			if current.PlannerFailure != nil {
				item.Detail = string(current.PlannerFailure.Kind)
			}
		case planningrunner.Superseded:
			item.State = review.StateReviewed
			item.Detail = "repair case was superseded by an existing import"
		case planningrunner.Decided, planningrunner.AlreadyDecided:
			encoded, err := contracts.EncodeDecision(current.Decision)
			if err != nil {
				return review.Snapshot{}, err
			}
			decision, err := review.ParseDecision(encoded)
			if err != nil {
				return review.Snapshot{}, err
			}
			item.Decision = &decision
			if decision.Action == string(contracts.ActionNoRepair) {
				item.State = review.StateReviewed
			} else {
				item.State = review.StateRepairPlanned
			}
			item.Detail = ""
		}
		items[queue.ID] = item
	}
	snapshot := review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceRadarr,
		GeneratedAt: generatedAt, Current: make([]review.Item, 0, len(items)),
	}
	for _, item := range items {
		snapshot.Current = append(snapshot.Current, item)
	}
	review.Sort(&snapshot)
	return snapshot, snapshot.Validate()
}

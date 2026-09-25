package review

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

const SnapshotVersion = "media-repair-review/v1"

type Service string

const (
	ServiceLidarr Service = "lidarr"
	ServiceRadarr Service = "radarr"
)

type State string

const (
	StateActive           State = "active"
	StateNotProcessed     State = "not_processed"
	StatePlanningDeferred State = "planning_deferred"
	StatePlanningFailed   State = "planning_failed"
	StateReviewed         State = "reviewed"
	StateRepairPlanned    State = "repair_planned"
	StateNoLongerQueued   State = "no_longer_queued"
)

type Decision struct {
	Action       string   `json:"action"`
	Reason       string   `json:"reason,omitempty"`
	Explanation  string   `json:"explanation"`
	EvidenceRefs []string `json:"evidence_refs"`
}

func ParseDecision(data []byte) (Decision, error) {
	var decision Decision
	if err := json.Unmarshal(data, &decision); err != nil {
		return Decision{}, fmt.Errorf("decode review decision: %w", err)
	}
	if strings.TrimSpace(decision.Action) == "" || strings.TrimSpace(decision.Explanation) == "" {
		return Decision{}, fmt.Errorf("review decision is incomplete")
	}
	decision.EvidenceRefs = append([]string(nil), decision.EvidenceRefs...)
	return decision, nil
}

type Item struct {
	QueueID           int64      `json:"queue_id"`
	Title             string     `json:"title"`
	Subject           string     `json:"subject,omitempty"`
	QueueStatus       string     `json:"queue_status"`
	TrackedStatus     string     `json:"tracked_status"`
	Protocol          string     `json:"protocol,omitempty"`
	State             State      `json:"state"`
	Detail            string     `json:"detail,omitempty"`
	CaseID            string     `json:"case_id,omitempty"`
	SourceFingerprint string     `json:"source_fingerprint,omitempty"`
	ObservedAt        *time.Time `json:"observed_at,omitempty"`
	LastSeenAt        time.Time  `json:"last_seen_at"`
	NoLongerQueuedAt  *time.Time `json:"no_longer_queued_at,omitempty"`
	Decision          *Decision  `json:"decision,omitempty"`
}

type Snapshot struct {
	Version     string    `json:"version"`
	Service     Service   `json:"service"`
	GeneratedAt time.Time `json:"generated_at"`
	Current     []Item    `json:"current"`
	History     []Item    `json:"history"`
}

func (snapshot Snapshot) Validate() error {
	if snapshot.Version != SnapshotVersion {
		return fmt.Errorf("unsupported review snapshot version %q", snapshot.Version)
	}
	if snapshot.Service != ServiceLidarr && snapshot.Service != ServiceRadarr {
		return fmt.Errorf("invalid review service %q", snapshot.Service)
	}
	if snapshot.GeneratedAt.IsZero() || snapshot.GeneratedAt.Location() != time.UTC {
		return fmt.Errorf("review snapshot time must be UTC")
	}
	seen := make(map[int64]struct{}, len(snapshot.Current))
	for index, item := range snapshot.Current {
		if err := validateItem(item, false); err != nil {
			return fmt.Errorf("current review item %d: %w", index, err)
		}
		if _, duplicate := seen[item.QueueID]; duplicate {
			return fmt.Errorf("duplicate current queue ID %d", item.QueueID)
		}
		seen[item.QueueID] = struct{}{}
	}
	for index, item := range snapshot.History {
		if err := validateItem(item, true); err != nil {
			return fmt.Errorf("historical review item %d: %w", index, err)
		}
	}
	return nil
}

func validateItem(item Item, historical bool) error {
	if item.QueueID <= 0 || strings.TrimSpace(item.Title) == "" || item.Title != strings.TrimSpace(item.Title) {
		return fmt.Errorf("queue identity is incomplete")
	}
	if item.LastSeenAt.IsZero() || item.LastSeenAt.Location() != time.UTC {
		return fmt.Errorf("last-seen time must be UTC")
	}
	if historical {
		if item.State != StateNoLongerQueued || item.NoLongerQueuedAt == nil ||
			item.NoLongerQueuedAt.IsZero() || item.NoLongerQueuedAt.Location() != time.UTC {
			return fmt.Errorf("historical queue state is incomplete")
		}
	} else if item.NoLongerQueuedAt != nil || !validCurrentState(item.State) {
		return fmt.Errorf("current queue state is invalid")
	}
	if item.Decision != nil {
		if item.CaseID == "" || strings.TrimSpace(item.Decision.Action) == "" ||
			strings.TrimSpace(item.Decision.Explanation) == "" {
			return fmt.Errorf("decision is incomplete")
		}
	}
	return nil
}

func validCurrentState(state State) bool {
	switch state {
	case StateActive, StateNotProcessed, StatePlanningDeferred, StatePlanningFailed,
		StateReviewed, StateRepairPlanned:
		return true
	default:
		return false
	}
}

func Sort(snapshot *Snapshot) {
	if snapshot == nil {
		return
	}
	sort.Slice(snapshot.Current, func(left, right int) bool {
		return snapshot.Current[left].QueueID < snapshot.Current[right].QueueID
	})
	sort.Slice(snapshot.History, func(left, right int) bool {
		leftAt := snapshot.History[left].NoLongerQueuedAt
		rightAt := snapshot.History[right].NoLongerQueuedAt
		if leftAt != nil && rightAt != nil && !leftAt.Equal(*rightAt) {
			return leftAt.After(*rightAt)
		}
		return snapshot.History[left].QueueID < snapshot.History[right].QueueID
	})
}

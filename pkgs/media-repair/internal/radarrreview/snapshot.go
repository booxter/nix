package radarrreview

import (
	"fmt"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/applyrunner"
	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/executioncheck"
	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/queueaction"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
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
		identity := queueaction.Identity(queuefinalize.Entry{
			QueueID: record.ID, DownloadID: record.DownloadID,
			Status: string(record.Status), TrackedDownloadStatus: string(record.TrackedDownloadStatus),
		})
		if record.MovieID != nil {
			identity.SubjectID = *record.MovieID
		}
		if identity.Entry().Eligible() {
			item := items[record.ID]
			item.QueueIdentity = &identity
			items[record.ID] = item
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
		if current.Reconsideration != nil {
			priorData, err := contracts.EncodeDecision(current.Reconsideration.Prior)
			if err != nil {
				return review.Snapshot{}, err
			}
			prior, err := review.ParseDecision(priorData)
			if err != nil {
				return review.Snapshot{}, err
			}
			description := review.NewReconsideration(
				current.Reconsideration.Request,
				current.Reconsideration.Result,
				current.Reconsideration.Decided,
				prior,
			)
			item.Reconsideration = &description
			item.Decision = &prior
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

func SnapshotWithApply(
	report shadowrunner.Report,
	apply applyrunner.Report,
	generatedAt time.Time,
) (review.Snapshot, error) {
	snapshot, err := Snapshot(report, generatedAt)
	if err != nil {
		return review.Snapshot{}, err
	}
	if err := applyExecutionResults(&snapshot, apply); err != nil {
		return review.Snapshot{}, err
	}
	return snapshot, snapshot.Validate()
}

func applyExecutionResults(snapshot *review.Snapshot, apply applyrunner.Report) error {
	items := make(map[string]int, len(snapshot.Current))
	for index := range snapshot.Current {
		if snapshot.Current[index].CaseID != "" {
			items[snapshot.Current[index].CaseID] = index
		}
	}
	results := make([]applyrunner.CaseResult, 0, len(apply.Executions)+len(apply.FinishedExecutions))
	results = append(results, apply.Executions...)
	results = append(results, apply.FinishedExecutions...)
	for _, execution := range results {
		failure := storedExecutionFailure(execution)
		block, blocked := storedExecutionBlock(execution)
		if failure == "" && !blocked {
			continue
		}
		index, found := items[execution.CaseID]
		if !found {
			return fmt.Errorf(
				"execution result refers to absent case %q",
				execution.CaseID,
			)
		}
		if failure != "" {
			snapshot.Current[index].State = review.StateExecutionFailed
			snapshot.Current[index].Detail = failure
			snapshot.Current[index].ExecutionFailure = failure
			continue
		}
		snapshot.Current[index].State = review.StateExecutionBlocked
		snapshot.Current[index].Detail = block.Reason
		if block.DecisionReason != "" {
			snapshot.Current[index].Detail += ": " + block.DecisionReason
		}
		snapshot.Current[index].ExecutionBlock = &block
	}
	return nil
}

func storedExecutionFailure(execution applyrunner.CaseResult) string {
	if execution.Failure != "" {
		return execution.Failure
	}
	if join := execution.Result.Join; join != nil {
		switch join.State {
		case casestore.JoinFailed:
			if join.Failure != nil {
				return fmt.Sprintf("join %s failed: %s", join.Failure.Operation, join.Failure.Reason)
			}
			return "join failed"
		case casestore.JoinImportFailed:
			return "joined-file import failed"
		}
	}
	if remux := execution.Result.Remux; remux != nil {
		switch remux.State {
		case casestore.RemuxFailed:
			if remux.Failure != nil {
				return fmt.Sprintf("remux %s failed: %s", remux.Failure.Operation, remux.Failure.Reason)
			}
			return "remux failed"
		case casestore.RemuxImportFailed:
			return "remux import failed"
		}
	}
	if manual := execution.Result.ManualImport; manual != nil &&
		manual.State == casestore.ManualImportFailed {
		return "manual import failed"
	}
	return ""
}

func storedExecutionBlock(execution applyrunner.CaseResult) (review.ExecutionBlock, bool) {
	if len(execution.Result.Check.Rejections) != 0 {
		return executionBlock(execution.Result.Check.Rejections[0]), true
	}
	join := execution.Result.Join
	if join == nil || join.State != casestore.JoinDiscarded || join.Stage == nil ||
		len(join.Stage.Rejections) == 0 {
		return review.ExecutionBlock{}, false
	}
	reasons := make([]string, len(join.Stage.Rejections))
	for index, reason := range join.Stage.Rejections {
		reasons[index] = string(reason)
	}
	return review.ExecutionBlock{
		Reason:         "staged_artifact_rejected",
		DecisionReason: strings.Join(reasons, ", "),
	}, true
}

func executionBlock(rejection executioncheck.Rejection) review.ExecutionBlock {
	block := review.ExecutionBlock{
		Reason:         string(rejection.Reason),
		DecisionReason: rejection.DecisionReason,
	}
	runtime := rejection.Runtime
	if runtime == nil || runtime.MovieRuntimeMS == nil || runtime.DifferenceMS == nil ||
		runtime.DefaultToleranceMS == nil || runtime.ToleranceMS == nil {
		return block
	}
	block.Runtime = &review.RuntimeAssessment{
		CandidateDurationMS: runtime.FileDurationMS,
		MovieRuntimeMS:      *runtime.MovieRuntimeMS,
		DifferenceMS:        *runtime.DifferenceMS,
		DefaultToleranceMS:  *runtime.DefaultToleranceMS,
		ActiveToleranceMS:   *runtime.ToleranceMS,
	}
	return block
}

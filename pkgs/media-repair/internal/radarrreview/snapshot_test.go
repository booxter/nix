package radarrreview

import (
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/applyrunner"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/executioncheck"
	"github.com/booxter/nix-config/media-repair/internal/repairexecution"
	"github.com/booxter/nix-config/media-repair/internal/review"
	shadowrunner "github.com/booxter/nix-config/media-repair/internal/shadow"
)

func TestSnapshotDistinguishesActiveAndUnprocessedWarnings(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 25, 2, 0, 0, 0, time.UTC)
	snapshot, err := Snapshot(shadowrunner.Report{Queue: []controller.RadarrQueueRecord{
		{ID: 1, Title: "Downloading", Status: "downloading", TrackedDownloadStatus: "ok"},
		{ID: 2, Title: "Needs review", Status: "completed", TrackedDownloadStatus: "warning"},
	}}, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Current) != 2 || snapshot.Current[0].State != review.StateActive ||
		snapshot.Current[1].State != review.StateNotProcessed {
		t.Fatalf("snapshot = %#v", snapshot)
	}
}

func TestApplyExecutionResultsMarksRejectedCaseBlocked(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 28, 2, 0, 0, 0, time.UTC)
	caseID := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	snapshot := review.Snapshot{
		Version: review.SnapshotVersion, Service: review.ServiceRadarr, GeneratedAt: now,
		Current: []review.Item{{
			QueueID: 1, Title: "Cabiria.1914.DVD5-NoGroup", QueueStatus: "completed",
			TrackedStatus: "warning", State: review.StateRepairPlanned,
			CaseID: caseID, LastSeenAt: now,
		}},
	}
	movieRuntime := int64(148 * 60 * 1_000)
	difference := int64(21.5 * 60 * 1_000)
	defaultTolerance := int64(14.8 * 60 * 1_000)
	apply := applyrunner.Report{Executions: []applyrunner.CaseResult{{
		CaseID: caseID,
		Result: repairexecution.Result{Check: executioncheck.Result{
			Rejections: []executioncheck.Rejection{{
				Reason:         executioncheck.DecisionRejected,
				DecisionReason: string(decisionpolicy.RemuxRuntimeMismatch),
				Runtime: &decisionpolicy.ManualImportRuntimeAssessment{
					FileDurationMS:     int64(126.5 * 60 * 1_000),
					MovieRuntimeMS:     &movieRuntime,
					DifferenceMS:       &difference,
					DefaultToleranceMS: &defaultTolerance,
					ToleranceMS:        &defaultTolerance,
				},
			}},
		}},
	}}}
	if err := applyExecutionResults(&snapshot, apply); err != nil {
		t.Fatal(err)
	}
	if err := snapshot.Validate(); err != nil {
		t.Fatal(err)
	}
	item := snapshot.Current[0]
	block := item.ExecutionBlock
	if item.State != review.StateExecutionBlocked || block == nil {
		t.Fatalf("review item = %#v", item)
	}
	if block.Reason != "decision_rejected" || block.DecisionReason != "runtime_mismatch" ||
		block.Runtime == nil || block.Runtime.CandidateDurationMS != int64(126.5*60*1_000) ||
		block.Runtime.MovieRuntimeMS != movieRuntime ||
		block.Runtime.DifferenceMS != difference ||
		block.Runtime.DefaultToleranceMS != defaultTolerance ||
		block.Runtime.ActiveToleranceMS != defaultTolerance {
		t.Fatalf("execution block = %#v", block)
	}
}

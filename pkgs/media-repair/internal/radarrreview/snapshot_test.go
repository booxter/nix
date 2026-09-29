package radarrreview

import (
	"os"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/applyrunner"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/executioncheck"
	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
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

func TestSnapshotWithApplyMarksRejectedCaseBlocked(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 28, 2, 0, 0, 0, time.UTC)
	caseID := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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
	report := snapshotReport(t, now, caseID)
	snapshot, err := SnapshotWithApply(report, apply, now)
	if err != nil {
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

func TestSnapshotWithApplySurfacesExecutionFailure(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 28, 2, 0, 0, 0, time.UTC)
	caseID := "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	wantFailure := "prepare DVD remux: DVD remux does not match stored case and decision"
	snapshot, err := SnapshotWithApply(
		snapshotReport(t, now, caseID),
		applyrunner.Report{Executions: []applyrunner.CaseResult{{
			CaseID: caseID, Failure: wantFailure,
		}}},
		now,
	)
	if err != nil {
		t.Fatal(err)
	}
	item := snapshot.Current[0]
	if item.State != review.StateExecutionFailed || item.Detail != wantFailure ||
		item.ExecutionFailure != wantFailure {
		t.Fatalf("review item = %#v", item)
	}
}

func snapshotReport(t *testing.T, now time.Time, caseID string) shadowrunner.Report {
	t.Helper()
	decisionData, err := os.ReadFile("../../contracts/v3/examples/repair-decision-no-repair.json")
	if err != nil {
		t.Fatal(err)
	}
	decision, err := contracts.DecodeDecision(decisionData)
	if err != nil {
		t.Fatal(err)
	}
	decision.NoRepair.CaseID = caseID
	return shadowrunner.Report{
		Queue: []controller.RadarrQueueRecord{{
			ID: 1, Title: "Cabiria.1914.DVD5-NoGroup", Status: "completed",
			TrackedDownloadStatus: "warning",
		}},
		Reviews: []shadowrunner.CaseReview{{
			Assembly: casebuilder.Assembly{
				Request: contracts.RepairCaseV3{CaseID: caseID, ObservedAt: now},
				LocalSnapshot: casebuilder.LocalSnapshot{
					CaseID: caseID,
					Observation: casebuilder.Observation{Correlation: controller.DownloadCorrelation{
						Radarr: controller.RadarrQueueRecord{ID: 1},
					}},
				},
			},
			Outcome: planningrunner.Decided, Decision: decision,
		}},
	}
}

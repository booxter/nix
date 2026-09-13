package shadow

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	dto "github.com/prometheus/client_model/go"
	"github.com/prometheus/common/expfmt"
	"github.com/prometheus/common/model"
)

func TestWriteMetricsReportsLatestShadowRun(t *testing.T) {
	t.Parallel()

	completedAt := time.Date(2026, time.September, 13, 18, 0, 0, 0, time.UTC)
	downloadCompletedAt := completedAt.Add(-2 * time.Hour)
	report := Report{
		Observed: 2, Stored: 1, Submitted: 2, Decided: 1, Failed: 1,
	}
	report.observe(casebuilder.Assembly{Request: contracts.RepairCaseV1{
		Radarr: contracts.Radarr{Failure: contracts.Failure{
			TrackedDownloadState: "importBlocked",
		}},
		Download: contracts.Download{CompletedAt: &downloadCompletedAt},
		Capabilities: []contracts.Capability{
			{Action: contracts.CapabilityActionJoinParts},
			{Action: contracts.CapabilityActionManualImportFile},
		},
	}})
	report.observe(casebuilder.Assembly{Request: contracts.RepairCaseV1{
		Radarr: contracts.Radarr{Failure: contracts.Failure{
			TrackedDownloadState: "importPending",
		}},
	}})
	report.observeDecision(contracts.RepairDecisionV1{
		Kind: contracts.ActionNoRepair,
		NoRepair: &contracts.NoRepairDecision{
			Reason: contracts.NoRepairDecisionReason("insufficient_evidence"),
		},
	})
	report.observePlannerFailure(casestore.PlanningFailureTimeout)
	report.metrics.collectionFailed = true
	report.metrics.plannerDuration = 8 * time.Second

	path := filepath.Join(t.TempDir(), "radarr-repair.prom")
	if err := WriteMetrics(path, report, false, completedAt); err != nil {
		t.Fatal(err)
	}
	families := readMetrics(t, path)
	assertMetric(t, families, metricsNamespace+"_shadow_run_success", nil, 0)
	assertMetric(t, families, metricsNamespace+"_shadow_collection_success", nil, 0)
	assertMetric(
		t, families, metricsNamespace+"_shadow_cases", map[string]string{"outcome": "observed"}, 2,
	)
	assertMetric(
		t, families, metricsNamespace+"_shadow_observations",
		map[string]string{"state": "importBlocked"}, 1,
	)
	assertMetric(
		t, families, metricsNamespace+"_shadow_capabilities",
		map[string]string{"action": "manual_import_file_v1"}, 1,
	)
	assertMetric(
		t, families, metricsNamespace+"_shadow_planner_decisions",
		map[string]string{"action": "no_repair"}, 1,
	)
	assertMetric(
		t, families, metricsNamespace+"_shadow_planner_abstentions",
		map[string]string{"reason": "insufficient_evidence"}, 1,
	)
	assertMetric(
		t, families, metricsNamespace+"_shadow_planner_failures",
		map[string]string{"reason": "planner_timeout"}, 1,
	)
	assertMetric(
		t, families, metricsNamespace+"_shadow_planner_request_duration_seconds", nil, 4,
	)
	assertMetric(
		t, families, metricsNamespace+"_shadow_oldest_download_age_seconds", nil, 7200,
	)

	if err := WriteMetrics(path, Report{}, true, completedAt.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	families = readMetrics(t, path)
	assertMetric(t, families, metricsNamespace+"_shadow_run_success", nil, 1)
	assertMetric(
		t, families, metricsNamespace+"_shadow_cases", map[string]string{"outcome": "observed"}, 0,
	)
}

func TestWriteMetricsRequiresCompletionTime(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "radarr-repair.prom")
	if err := WriteMetrics(path, Report{}, true, time.Time{}); err == nil {
		t.Fatal("zero completion time was accepted")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("metrics file exists after rejected write: %v", err)
	}
}

func readMetrics(t *testing.T, path string) map[string]*dto.MetricFamily {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	parser := expfmt.NewTextParser(model.UTF8Validation)
	families, err := parser.TextToMetricFamilies(strings.NewReader(string(data)))
	if err != nil {
		t.Fatalf("parse metrics: %v", err)
	}
	return families
}

func assertMetric(
	t *testing.T,
	families map[string]*dto.MetricFamily,
	name string,
	labels map[string]string,
	want float64,
) {
	t.Helper()
	family := families[name]
	if family == nil {
		t.Fatalf("metric family %q is missing", name)
	}
	for _, metric := range family.Metric {
		if metricLabelsEqual(metric, labels) {
			if got := metric.GetGauge().GetValue(); got != want {
				t.Fatalf("metric %s%v = %v, want %v", name, labels, got, want)
			}
			return
		}
	}
	t.Fatalf("metric %s%v is missing", name, labels)
}

func metricLabelsEqual(metric *dto.Metric, wanted map[string]string) bool {
	if len(metric.Label) != len(wanted) {
		return false
	}
	for _, pair := range metric.Label {
		if wanted[pair.GetName()] != pair.GetValue() {
			return false
		}
	}
	return true
}

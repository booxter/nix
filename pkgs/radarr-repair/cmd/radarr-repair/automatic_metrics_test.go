package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/applyrunner"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/executioncheck"
	"github.com/booxter/nix-config/radarr-repair/internal/repairexecution"
	shadowrunner "github.com/booxter/nix-config/radarr-repair/internal/shadow"
	dto "github.com/prometheus/client_model/go"
	"github.com/prometheus/common/expfmt"
	"github.com/prometheus/common/model"
)

func TestAutomaticMetricsReportBoundedApplyOutcomes(t *testing.T) {
	t.Parallel()

	report := automaticReport{
		Apply: applyrunner.Report{
			Permitted: 4,
			Finished:  1,
			Selected:  3,
			Executions: []applyrunner.CaseResult{
				{
					CaseID: "private-case-id",
					Action: contracts.ActionJoinParts,
					Result: repairexecution.Result{Check: executioncheck.Result{
						Rejections: []executioncheck.Rejection{{
							Reason: executioncheck.CaseChanged,
						}},
					}},
				},
				{
					CaseID: "manual-import",
					Action: contracts.ActionManualImportFile,
					Result: repairexecution.Result{
						ManualImport: &casestore.ManualImportExecution{
							State: casestore.ManualImportImported,
						},
					},
				},
				{
					CaseID: "failed-join",
					Action: contracts.ActionJoinParts,
					Result: repairexecution.Result{Join: &casestore.JoinExecution{
						State: casestore.JoinFailed,
					}},
				},
			},
		},
	}
	path := writeAutomaticMetrics(t, report, false)
	families, data := readAutomaticMetrics(t, path)
	prefix := shadowrunner.MetricsNamespace
	assertAutomaticMetric(t, families, prefix+"_apply_run_success", nil, 0)
	assertAutomaticMetric(t, families, prefix+"_apply_disabled", nil, 0)
	assertAutomaticMetric(
		t, families, prefix+"_apply_cases", map[string]string{"outcome": "permitted"}, 4,
	)
	assertAutomaticMetric(
		t, families, prefix+"_apply_cases", map[string]string{"outcome": "executed"}, 3,
	)
	assertAutomaticMetric(
		t,
		families,
		prefix+"_apply_precondition_rejections",
		map[string]string{"reason": string(executioncheck.CaseChanged)},
		1,
	)
	assertAutomaticMetric(
		t,
		families,
		prefix+"_apply_executions",
		map[string]string{
			"action": string(contracts.ActionJoinParts),
			"state":  "precondition_rejected",
		},
		1,
	)
	assertAutomaticMetric(
		t,
		families,
		prefix+"_apply_executions",
		map[string]string{
			"action": string(contracts.ActionManualImportFile),
			"state":  string(casestore.ManualImportImported),
		},
		1,
	)
	assertAutomaticMetric(
		t,
		families,
		prefix+"_apply_executions",
		map[string]string{
			"action": string(contracts.ActionJoinParts),
			"state":  string(casestore.JoinFailed),
		},
		1,
	)
	if strings.Contains(data, "private-case-id") || strings.Contains(data, "manual-import") {
		t.Fatalf("metrics contain a case ID: %s", data)
	}
}

func TestAutomaticMetricsReportDisabledRun(t *testing.T) {
	t.Parallel()

	path := writeAutomaticMetrics(t, automaticReport{ApplyDisabled: true}, true)
	families, _ := readAutomaticMetrics(t, path)
	prefix := shadowrunner.MetricsNamespace
	assertAutomaticMetric(t, families, prefix+"_apply_run_success", nil, 1)
	assertAutomaticMetric(t, families, prefix+"_apply_disabled", nil, 1)
	assertAutomaticMetric(
		t, families, prefix+"_apply_cases", map[string]string{"outcome": "selected"}, 0,
	)
	assertAutomaticMetric(
		t,
		families,
		prefix+"_apply_precondition_rejections",
		map[string]string{"reason": string(executioncheck.StabilizationPending)},
		0,
	)
}

func TestAutomaticMetricsReportExecutorErrorWithoutDurableState(t *testing.T) {
	t.Parallel()

	report := automaticReport{Apply: applyrunner.Report{
		Selected: 1,
		Executions: []applyrunner.CaseResult{{
			Action: contracts.ActionManualImportFile,
		}},
	}}
	path := writeAutomaticMetrics(t, report, false)
	families, _ := readAutomaticMetrics(t, path)
	assertAutomaticMetric(
		t,
		families,
		shadowrunner.MetricsNamespace+"_apply_executions",
		map[string]string{
			"action": string(contracts.ActionManualImportFile),
			"state":  "executor_error",
		},
		1,
	)
}

func writeAutomaticMetrics(
	t *testing.T,
	report automaticReport,
	successful bool,
) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "radarr-repair.prom")
	if err := shadowrunner.WriteMetrics(
		path,
		report.Shadow,
		report.ShadowSucceeded,
		time.Date(2026, time.September, 14, 12, 0, 0, 0, time.UTC),
		automaticMetrics(report, successful)...,
	); err != nil {
		t.Fatal(err)
	}
	return path
}

func readAutomaticMetrics(
	t *testing.T,
	path string,
) (map[string]*dto.MetricFamily, string) {
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
	return families, string(data)
}

func assertAutomaticMetric(
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
		if automaticMetricLabelsEqual(metric, labels) {
			if got := metric.GetGauge().GetValue(); got != want {
				t.Fatalf("metric %s%v = %v, want %v", name, labels, got, want)
			}
			return
		}
	}
	t.Fatalf("metric %s%v is missing", name, labels)
}

func automaticMetricLabelsEqual(metric *dto.Metric, wanted map[string]string) bool {
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

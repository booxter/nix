package main

import (
	"github.com/booxter/nix-config/radarr-repair/internal/applyrunner"
	"github.com/booxter/nix-config/radarr-repair/internal/executioncheck"
	shadowrunner "github.com/booxter/nix-config/radarr-repair/internal/shadow"
	"github.com/prometheus/client_golang/prometheus"
)

var automaticRejectionReasons = [...]executioncheck.RejectionReason{
	executioncheck.DecisionRejected,
	executioncheck.StabilizationPending,
	executioncheck.CaseUnavailable,
	executioncheck.CaseChanged,
	executioncheck.AuthorizationChanged,
	executioncheck.SupersededReplacement,
	executioncheck.UnprovedReplacement,
	executioncheck.JoinExecutionPresent,
}

func automaticMetrics(report automaticReport, successful bool) []prometheus.Collector {
	runSuccess := prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: shadowrunner.MetricsNamespace,
		Name:      "apply_run_success",
		Help:      "Whether the latest automatic run completed without an error.",
	})
	runSuccess.Set(boolMetricValue(successful))
	disabled := prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: shadowrunner.MetricsNamespace,
		Name:      "apply_disabled",
		Help:      "Whether the latest automatic run stopped at the apply kill switch.",
	})
	disabled.Set(boolMetricValue(report.ApplyDisabled))

	cases := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: shadowrunner.MetricsNamespace,
		Name:      "apply_cases",
		Help:      "Cases handled in the latest automatic run by outcome.",
	}, []string{"outcome"})
	cases.WithLabelValues("permitted").Set(float64(report.Apply.Permitted))
	cases.WithLabelValues("finished").Set(float64(report.Apply.Finished))
	cases.WithLabelValues("selected").Set(float64(report.Apply.Selected))
	cases.WithLabelValues("attempted").Set(float64(len(report.Apply.Executions)))

	rejectionCounts := make(map[executioncheck.RejectionReason]int)
	executionCounts := make(map[automaticExecutionOutcome]int)
	for _, execution := range report.Apply.Executions {
		for _, rejection := range execution.Result.Check.Rejections {
			rejectionCounts[rejection.Reason]++
		}
		outcome := automaticExecutionOutcome{
			action: string(execution.Action),
			state:  automaticExecutionState(execution),
		}
		executionCounts[outcome]++
	}

	rejections := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: shadowrunner.MetricsNamespace,
		Name:      "apply_precondition_rejections",
		Help:      "Fresh-state check rejections in the latest automatic run by reason.",
	}, []string{"reason"})
	for _, reason := range automaticRejectionReasons {
		rejections.WithLabelValues(string(reason)).Set(float64(rejectionCounts[reason]))
	}

	executions := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: shadowrunner.MetricsNamespace,
		Name:      "apply_executions",
		Help:      "Executions in the latest automatic run by action and resulting state.",
	}, []string{"action", "state"})
	for outcome, count := range executionCounts {
		executions.WithLabelValues(outcome.action, outcome.state).Set(float64(count))
	}

	return []prometheus.Collector{runSuccess, disabled, cases, rejections, executions}
}

type automaticExecutionOutcome struct {
	action string
	state  string
}

func automaticExecutionState(execution applyrunner.CaseResult) string {
	result := execution.Result
	switch {
	case len(result.Check.Rejections) != 0:
		return "precondition_rejected"
	case result.ManualImport != nil:
		return string(result.ManualImport.State)
	case result.Join != nil:
		return string(result.Join.State)
	default:
		return "executor_error"
	}
}

func boolMetricValue(value bool) float64 {
	if value {
		return 1
	}
	return 0
}

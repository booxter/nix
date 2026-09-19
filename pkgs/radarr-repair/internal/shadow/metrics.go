package shadow

import (
	"fmt"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

const MetricsNamespace = "host_observability_radarr_repair"

func WriteMetrics(
	path string,
	report Report,
	successful bool,
	completedAt time.Time,
	additional ...prometheus.Collector,
) error {
	if completedAt.IsZero() {
		return fmt.Errorf("metrics completion time is required")
	}

	registry := prometheus.NewPedanticRegistry()
	registerGauge(registry, "shadow_run_success", "Whether the latest shadow run succeeded.", boolValue(successful))
	registerGauge(
		registry,
		"shadow_collection_success",
		"Whether case collection completed without an error in the latest shadow run.",
		boolValue(!report.metrics.collectionFailed),
	)
	registerGauge(
		registry,
		"shadow_last_run_timestamp_seconds",
		"Unix timestamp when the latest shadow run completed.",
		float64(completedAt.UTC().Unix()),
	)

	cases := newGaugeVector(
		registry,
		"shadow_cases",
		"Cases handled in the latest shadow run by outcome.",
		"outcome",
	)
	setGaugeValues(cases, []labeledValue{
		{label: "observed", value: report.Observed},
		{label: "stored", value: report.Stored},
		{label: "superseded", value: report.Superseded},
		{label: "submitted", value: report.Submitted},
		{label: "decided", value: report.Decided},
		{label: "already_decided", value: report.AlreadyDecided},
		{label: "deferred", value: report.Deferred},
		{label: "failed", value: report.Failed},
	})

	states := newGaugeVector(
		registry,
		"shadow_observations",
		"Observations in the latest shadow run by Radarr lifecycle state.",
		"state",
	)
	setGaugeValues(states, []labeledValue{
		{label: "importBlocked", value: report.metrics.lifecycleStates[lifecycleImportBlocked]},
		{label: "importPending", value: report.metrics.lifecycleStates[lifecycleImportPending]},
		{label: "other", value: report.metrics.lifecycleStates[lifecycleOther]},
	})

	capabilities := newGaugeVector(
		registry,
		"shadow_capabilities",
		"Capabilities offered in the latest shadow run by action.",
		"action",
	)
	setGaugeValues(capabilities, []labeledValue{
		{label: "join_parts_v1", value: report.metrics.capabilities[capabilityJoinParts]},
		{
			label: "manual_import_file_v1",
			value: report.metrics.capabilities[capabilityManualImportFile],
		},
		{label: "remux_bluray_v1", value: report.metrics.capabilities[capabilityRemuxBluray]},
		{label: "remux_dvd_v1", value: report.metrics.capabilities[capabilityRemuxDVD]},
	})

	decisions := newGaugeVector(
		registry,
		"shadow_planner_decisions",
		"New decisions returned in the latest shadow run by action.",
		"action",
	)
	setGaugeValues(decisions, []labeledValue{
		{label: "no_repair", value: report.metrics.decisions[decisionNoRepair]},
		{label: "join_parts_v1", value: report.metrics.decisions[decisionJoinParts]},
		{
			label: "manual_import_file_v1",
			value: report.metrics.decisions[decisionManualImportFile],
		},
		{label: "remux_bluray_v1", value: report.metrics.decisions[decisionRemuxBluray]},
		{label: "remux_dvd_v1", value: report.metrics.decisions[decisionRemuxDVD]},
	})

	abstentions := newGaugeVector(
		registry,
		"shadow_planner_abstentions",
		"New no-repair decisions in the latest shadow run by reason.",
		"reason",
	)
	for index, reason := range noRepairReasons {
		abstentions.WithLabelValues(string(reason)).Set(float64(report.metrics.noRepair[index]))
	}

	failures := newGaugeVector(
		registry,
		"shadow_planner_failures",
		"Planner request failures in the latest shadow run by reason.",
		"reason",
	)
	for index, reason := range plannerFailureKinds {
		failures.WithLabelValues(string(reason)).Set(float64(report.metrics.plannerFailures[index]))
	}

	averagePlannerDuration := 0.0
	if report.Submitted > 0 {
		averagePlannerDuration = report.metrics.plannerDuration.Seconds() / float64(report.Submitted)
	}
	registerGauge(
		registry,
		"shadow_planner_request_duration_seconds",
		"Average planner request duration in the latest shadow run.",
		averagePlannerDuration,
	)

	oldestDownloadAge := 0.0
	if !report.metrics.oldestCompletedAt.IsZero() && completedAt.After(report.metrics.oldestCompletedAt) {
		oldestDownloadAge = completedAt.Sub(report.metrics.oldestCompletedAt).Seconds()
	}
	registerGauge(
		registry,
		"shadow_oldest_download_age_seconds",
		"Age of the oldest completed download observed in the latest shadow run.",
		oldestDownloadAge,
	)
	for _, collector := range additional {
		if collector == nil {
			return fmt.Errorf("additional metrics collector is required")
		}
		if err := registry.Register(collector); err != nil {
			return fmt.Errorf("register additional metrics: %w", err)
		}
	}

	if err := prometheus.WriteToTextfile(path, registry); err != nil {
		return fmt.Errorf("write controller metrics: %w", err)
	}
	return nil
}

type labeledValue struct {
	label string
	value int
}

func boolValue(value bool) float64 {
	if value {
		return 1
	}
	return 0
}

func registerGauge(
	registry *prometheus.Registry,
	name string,
	help string,
	value float64,
) {
	gauge := prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: MetricsNamespace,
		Name:      name,
		Help:      help,
	})
	gauge.Set(value)
	registry.MustRegister(gauge)
}

func newGaugeVector(
	registry *prometheus.Registry,
	name string,
	help string,
	label string,
) *prometheus.GaugeVec {
	gauge := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: MetricsNamespace,
		Name:      name,
		Help:      help,
	}, []string{label})
	registry.MustRegister(gauge)
	return gauge
}

func setGaugeValues(gauge *prometheus.GaugeVec, values []labeledValue) {
	for _, value := range values {
		gauge.WithLabelValues(value.label).Set(float64(value.value))
	}
}

package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

type fleetSeries struct {
	title      string
	expression string
	legend     string
	unit       string
	thresholds *dashboard.ThresholdsConfigBuilder
	min        *float64
	max        *float64
}

func FleetOverview(config Config) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	node := func(metric string, matchers ...string) string {
		return nodeMetric(metric, matchers...)
	}

	memoryUsed := `100 * ((1 - (` + node("node_memory_MemAvailable_bytes") + ` / ` +
		node("node_memory_MemTotal_bytes") + `)) or (1 - ((` + node("node_memory_free_bytes") + ` + ` +
		node("node_memory_inactive_bytes") + `) / ` + node("node_memory_total_bytes") + `)))`
	rootUsed := `100 * (1 - (` + node("node_filesystem_avail_bytes", `mountpoint="/"`, `fstype!=""`) +
		` / ` + node("node_filesystem_size_bytes", `mountpoint="/"`, `fstype!=""`) + `))`
	swapTotal := node("node_memory_SwapTotal_bytes")

	series := []fleetSeries{
		{
			title: "Node Exporter Up", unit: units.Short, legend: "{{instance}}",
			expression: node("up"), thresholds: redToGreenThreshold(1), min: ptr(0.0), max: ptr(1.0),
		},
		{
			title: "CPU Busy", unit: units.Percent, legend: "{{instance}}",
			expression: `100 - (avg by(instance) (rate(` + node("node_cpu_seconds_total", `mode="idle"`) + `[5m])) * 100)`,
			thresholds: warningCriticalThresholds(70, 90), min: ptr(0.0), max: ptr(100.0),
		},
		{
			title: "Memory Used", unit: units.Percent, legend: "{{instance}}",
			expression: memoryUsed, thresholds: warningCriticalThresholds(75, 90), min: ptr(0.0), max: ptr(100.0),
		},
		{
			title: "Root Filesystem Used", unit: units.Percent, legend: "{{instance}}",
			expression: rootUsed, thresholds: warningCriticalThresholds(75, 90), min: ptr(0.0), max: ptr(100.0),
		},
		{
			title: "Disk I/O Throughput", unit: units.BytesPerSecondSI, legend: "{{instance}}",
			expression: `sum by(instance) (rate(` + node("node_disk_read_bytes_total") + `[5m]) + rate(` +
				node("node_disk_written_bytes_total") + `[5m]))`, min: ptr(0.0),
		},
		{
			title: "Uptime", unit: units.DurationInDaysHoursMinutesSeconds, legend: "{{instance}}",
			expression: `time() - ` + node("node_boot_time_seconds"), min: ptr(0.0),
		},
		{
			title: "Time Since Last Successful NixOS Upgrade", unit: units.DurationInDaysHoursMinutesSeconds,
			legend: "{{instance}}", expression: `time() - ` + node("node_nixos_upgrade_last_success_time_seconds"),
			min: ptr(0.0),
		},
		{
			title: "Swap Used", unit: units.Percent, legend: "{{instance}}",
			expression: `100 * (1 - (` + node("node_memory_SwapFree_bytes") + ` / ` + swapTotal +
				`)) and on(instance) ` + swapTotal + ` > 0`,
			thresholds: warningCriticalThresholds(70, 80), min: ptr(0.0), max: ptr(100.0),
		},
		{
			title: "Swap Capacity", unit: units.BytesIEC, legend: "{{instance}}",
			expression: swapTotal + ` > 0`, min: ptr(0.0),
		},
		{
			title: "Swap Churn", unit: units.PacketsPerSecond, legend: "{{instance}}",
			expression: `rate(` + node("node_vmstat_pswpin") + `[5m]) + rate(` + node("node_vmstat_pswpout") + `[5m])`,
			thresholds: absoluteThresholds(
				dashboard.Threshold{Color: "green", Value: nil},
				dashboard.Threshold{Color: "orange", Value: ptr(1000.0)},
			),
			min: ptr(0.0),
		},
	}

	builder := newDashboard(DashboardOptions{
		Title: "Fleet", UID: "fana-fleet-overview", Tags: []string{"fleet", "overview"},
		From: "now-6h", Refresh: "30s",
	})
	placements := make([]panelPlacement, 0, len(series))
	placements = append(placements, layout.row(8, 12, 12)...)
	placements = append(placements, layout.row(8, 12, 12)...)
	placements = append(placements, layout.row(8, 24)...)
	placements = append(placements, layout.row(8, 12, 12)...)
	placements = append(placements, layout.row(8, 8, 8, 8)...)
	for index, definition := range series {
		placement := placements[index]
		builder.WithPanel(timeSeries(TimeseriesOptions{
			ID: placement.ID, Grid: placement.Grid, Title: definition.title,
			Unit: definition.unit, DataSource: datasource, Min: definition.min, Max: definition.max,
			Thresholds: definition.thresholds,
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: definition.expression, Legend: definition.legend,
			}},
		}))
	}

	return builder.Build()
}

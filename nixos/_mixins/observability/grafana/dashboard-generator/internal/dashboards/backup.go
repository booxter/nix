package dashboards

import (
	"fmt"

	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func BackupOverview(config Config) (dashboard.Dashboard, error) {
	server, err := config.backupServer()
	if err != nil {
		return dashboard.Dashboard{}, err
	}

	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	serverMetric := func(name string, matchers ...string) string {
		return nodeMetric(name, append([]string{fmt.Sprintf("instance=%q", server)}, matchers...)...)
	}

	builder := newDashboard(DashboardOptions{
		Title: "Backups", UID: "fana-backup-overview", Tags: []string{"backup", "restic", "b2"},
		From: "now-7d", Refresh: "5m",
	})
	summary := layout.row(5, 6, 6, 6, 6)
	stats := []struct {
		title      string
		expression string
		legend     string
		unit       string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{
			title: "Failed Backup Jobs", legend: "failed", unit: units.Short,
			expression: "sum(1 - " + nodeMetric("host_observability_backup_last_success") + ") or vector(0)",
			thresholds: greenToRedThreshold(1),
		},
		{
			title: "Oldest Successful Backup Age", legend: "oldest", unit: units.Hours,
			expression: "max((time() - " + nodeMetric("host_observability_backup_last_success_timestamp_seconds") + ") / 3600) or vector(0)",
			thresholds: warningCriticalThresholds(24, 48),
		},
		{
			title: "B2 Bucket Usage", legend: server, unit: units.BytesIEC,
			expression: "sum(" + serverMetric("host_observability_b2_bucket_total_size_bytes") + ") or vector(0)",
		},
		{
			title: "B2 Files and Versions", legend: server, unit: units.Short,
			expression: "sum(" + serverMetric("host_observability_b2_bucket_files") + ") or vector(0)",
		},
	}
	for index, definition := range stats {
		placement := summary[index]
		builder.WithPanel(valueStat(ValueStatOptions{
			ID: placement.ID, Grid: placement.Grid, Title: definition.title,
			Expression: definition.expression, Legend: definition.legend, Unit: definition.unit,
			DataSource: datasource, Thresholds: definition.thresholds,
		}))
	}

	cloudStats := layout.row(5, 12, 12)
	builder.
		WithPanel(valueStat(ValueStatOptions{
			ID: cloudStats[0].ID, Grid: cloudStats[0].Grid, Title: "Estimated B2 Storage / Month",
			Expression: "clamp_min(sum(" + serverMetric("host_observability_b2_bucket_total_size_bytes") +
				") - 10000000000, 0) / 1000000000 * 0.00695 or vector(0)",
			Legend: "estimated", Unit: units.Dollars, DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: cloudStats[1].ID, Grid: cloudStats[1].Grid, Title: "B2 Usage Data Age",
			Expression: "max((time() - " + serverMetric("host_observability_b2_bucket_usage_last_success_timestamp_seconds") +
				") / 3600) or vector(0)",
			Legend: "age", Unit: units.Hours, DataSource: datasource,
			Thresholds: warningCriticalThresholds(30, 48),
		}))

	cloudSeries := layout.row(8, 24)[0]
	builder.WithPanel(timeSeries(TimeseriesOptions{
		ID: cloudSeries.ID, Grid: cloudSeries.Grid, Title: "Cloud Repository Raw Size",
		Unit: units.BytesIEC, DataSource: datasource, Min: ptr(0.0),
		Targets: []PrometheusTarget{{
			RefID: "A", Expression: serverMetric("host_observability_restic_cloud_repository_total_size_bytes"),
			Legend: "{{host}} / {{repository}}",
		}},
	}))

	tables := []struct {
		title      string
		expression string
		unit       string
	}{
		{
			title:      "Latest Backup Result Details",
			expression: nodeMetric("host_observability_backup_last_result_info"),
		},
		{
			title: "Backup Success Age (hours)", unit: units.Hours,
			expression: "(time() - " + nodeMetric("host_observability_backup_last_success_timestamp_seconds") + ") / 3600",
		},
		{
			title: "Latest Backup Duration (minutes)", unit: units.Minutes,
			expression: nodeMetric("host_observability_backup_last_duration_seconds") + " / 60",
		},
		{
			title: "Cloud Repository Raw Size by Host", unit: units.BytesIEC,
			expression: serverMetric("host_observability_restic_cloud_repository_total_size_bytes"),
		},
	}
	for offset := 0; offset < len(tables); offset += 2 {
		placements := layout.row(8, 12, 12)
		for index, placement := range placements {
			definition := tables[offset+index]
			builder.WithPanel(metricTable(MetricTableOptions{
				ID: placement.ID, Grid: placement.Grid, Title: definition.title,
				Expression: definition.expression, Unit: definition.unit, DataSource: datasource,
			}))
		}
	}

	results := layout.row(8, 24)[0]
	builder.WithPanel(metricTable(MetricTableOptions{
		ID: results.ID, Grid: results.Grid, Title: "Cloud Usage Collection Results",
		Expression: serverMetric("host_observability_b2_bucket_usage_last_result_info") + " or " +
			serverMetric("host_observability_restic_cloud_repository_stats_last_result_info"),
		DataSource: datasource,
	}))

	return builder.Build()
}

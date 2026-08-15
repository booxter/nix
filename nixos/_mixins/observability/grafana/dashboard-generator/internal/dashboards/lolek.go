package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

const lolekService = "lolek"

func LolekOverview(config Config) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	metric := func(name string, matchers ...string) string {
		return applicationMetric(name, lolekService, matchers...)
	}
	activeJobThresholds := absoluteThresholds(
		dashboard.Threshold{Color: "green", Value: nil},
		dashboard.Threshold{Color: "orange", Value: ptr(3.0)},
		dashboard.Threshold{Color: "red", Value: ptr(4.0)},
	)

	builder := newDashboard(DashboardOptions{
		Title: "Lolek Bot", UID: "lolek-bot", Tags: []string{"bot", "lolek", "observability"},
		From: "now-24h", Refresh: "30s",
	})
	stats := layout.row(4, 6, 6, 6, 6)
	builder.WithPanel(availabilityStat(AvailabilityStatOptions{
		ID: stats[0].ID, Grid: stats[0].Grid, Title: "Scrape",
		Expression: metric("up"), Legend: "scrape", DataSource: datasource,
	}))
	statDefinitions := []struct {
		title      string
		expression string
		legend     string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{title: "Active Jobs", expression: metric("lolek_processing_active"), legend: "active", thresholds: activeJobThresholds},
		{
			title: "Messages In Range", legend: "messages",
			expression: "round(sum(increase(" + metric("lolek_messages_total") +
				"[$__range]))) or vector(0)",
		},
		{
			title: "Rate Limited In Range", legend: "rejected",
			expression: "round(sum(increase(" + metric("lolek_chat_rate_limiter_total", `result="rejected"`) +
				"[$__range]))) or vector(0)",
			thresholds: absoluteThresholds(
				dashboard.Threshold{Color: "green", Value: nil},
				dashboard.Threshold{Color: "orange", Value: ptr(1.0)},
				dashboard.Threshold{Color: "red", Value: ptr(5.0)},
			),
		},
	}
	for index, definition := range statDefinitions {
		placement := stats[index+1]
		builder.WithPanel(valueStat(ValueStatOptions{
			ID: placement.ID, Grid: placement.Grid, Title: definition.title,
			Expression: definition.expression, Legend: definition.legend,
			Unit: units.Short, DataSource: datasource, Thresholds: definition.thresholds,
		}))
	}

	timeSeriesDefinitions := []struct {
		title      string
		expression string
		legend     string
		unit       string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{
			title: "Message Rate", unit: units.OpsPerSecond, legend: "{{result}}",
			expression: "sum by(result) (rate(" + metric("lolek_messages_total") + "[5m]))",
		},
		{
			title: "Processing Stage Duration", unit: units.Seconds, legend: "p95 {{stage}}",
			expression: "histogram_quantile(0.95, sum by(le, stage) (rate(" +
				metric("lolek_processing_stage_duration_seconds_bucket") + "[10m])))",
			thresholds: absoluteThresholds(
				dashboard.Threshold{Color: "green", Value: nil},
				dashboard.Threshold{Color: "orange", Value: ptr(30.0)},
				dashboard.Threshold{Color: "red", Value: ptr(120.0)},
			),
		},
		{
			title: "Processing Stage Rate", unit: units.OpsPerSecond, legend: "{{stage}} / {{result}}",
			expression: "sum by(stage, result) (rate(" + metric("lolek_processing_stage_total") + "[5m]))",
		},
		{
			title: "Cache Lookup Rate", unit: units.OpsPerSecond, legend: "{{state}}",
			expression: "sum by(state) (rate(" + metric("lolek_cache_lookup_total") + "[5m]))",
		},
		{
			title: "Rate Limiter Rate", unit: units.OpsPerSecond, legend: "{{result}}",
			expression: "sum by(result) (rate(" + metric("lolek_chat_rate_limiter_total") + "[5m]))",
			thresholds: absoluteThresholds(
				dashboard.Threshold{Color: "green", Value: nil},
				dashboard.Threshold{Color: "orange", Value: ptr(0.1)},
			),
		},
		{
			title: "Active Jobs", unit: units.Short, legend: "active",
			expression: metric("lolek_processing_active"), thresholds: activeJobThresholds,
		},
	}
	for offset := 0; offset < len(timeSeriesDefinitions); offset += 2 {
		placements := layout.row(8, 12, 12)
		for index, placement := range placements {
			definition := timeSeriesDefinitions[offset+index]
			builder.WithPanel(timeSeries(TimeseriesOptions{
				ID: placement.ID, Grid: placement.Grid, Title: definition.title,
				Unit: definition.unit, DataSource: datasource, Thresholds: definition.thresholds,
				Targets: []PrometheusTarget{{
					RefID: "A", Expression: definition.expression, Legend: definition.legend,
				}},
			}))
		}
	}

	return builder.Build()
}

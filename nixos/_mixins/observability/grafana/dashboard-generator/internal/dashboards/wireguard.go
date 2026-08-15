package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func WireGuardOverview(config Config) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	metric := func(name string, matchers ...string) string {
		return profileMetric(name, "network", append([]string{`component="wireguard"`}, matchers...)...)
	}
	summary := layout.row(6, 8, 8, 8)
	builder := newDashboard(DashboardOptions{
		Title: "WireGuard", UID: "fana-wireguard", Tags: []string{"wireguard", "network"},
		From: "now-6h", Refresh: "30s",
	}).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: summary[0].ID, Grid: summary[0].Grid, Title: "Exporter Scrape",
			Expression: metric("up"), Legend: "{{instance}}", DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[1].ID, Grid: summary[1].Grid, Title: "Peer Connection Status",
			Expression: metric("wireguard_latest_handshake_delay_seconds") + " <= bool 180",
			Legend:     "{{friendly_name}}", Unit: units.Short, DataSource: datasource,
			Min: ptr(0.0), Max: ptr(1.0), Mappings: []dashboard.ValueMapping{availabilityMapping()},
			Background: true, Thresholds: redToGreenThreshold(1),
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[2].ID, Grid: summary[2].Grid, Title: "Current Handshake Age",
			Expression: metric("wireguard_latest_handshake_delay_seconds"),
			Legend:     "{{friendly_name}}", Unit: units.Seconds, DataSource: datasource,
			Thresholds: warningCriticalThresholds(120, 180),
		}))

	details := layout.row(8, 12, 12)
	builder.
		WithPanel(timeSeries(TimeseriesOptions{
			ID: details[0].ID, Grid: details[0].Grid, Title: "Peer Traffic Rate",
			Unit: units.BitsPerSecondSI, DataSource: datasource, Min: ptr(0.0),
			Targets: []PrometheusTarget{
				{
					RefID: "A", Legend: "Receive {{friendly_name}}",
					Expression: "rate(" + metric("wireguard_received_bytes_total") + "[5m]) * 8",
				},
				{
					RefID: "B", Legend: "Send {{friendly_name}}",
					Expression: "rate(" + metric("wireguard_sent_bytes_total") + "[5m]) * 8",
				},
			},
		})).
		WithPanel(metricTable(MetricTableOptions{
			ID: details[1].ID, Grid: details[1].Grid, Title: "Peer Snapshot",
			Expression: metric("wireguard_latest_handshake_delay_seconds"), Unit: units.Seconds,
			DataSource: datasource,
		}))

	return builder.Build()
}

package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func UnifiOverview(config Config) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	selector := `scrape_profile="network",component="unpoller"`
	metric := func(name string, matchers ...string) string {
		return profileMetric(name, "network", append([]string{`component="unpoller"`}, matchers...)...)
	}

	summary := layout.row(5, 6, 6, 6, 6)
	builder := newDashboard(DashboardOptions{
		Title: "UniFi WAN", UID: "fana-unifi-wan", Tags: []string{"unifi", "network", "wan"},
		From: "now-24h", Refresh: "1m",
	}).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: summary[0].ID, Grid: summary[0].Grid, Title: "Exporter",
			Expression: `up{` + selector + `}`, Legend: "Unpoller", DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[1].ID, Grid: summary[1].Grid, Title: "Gateway Uptime",
			Expression: "max by (name) (" + metric("unpoller_device_uptime_seconds") + ")",
			Legend:     "{{name}}", Unit: units.DurationInDaysHoursMinutesSeconds, DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[2].ID, Grid: summary[2].Grid, Title: "Current WAN Latency",
			Expression: "max by (site_name) (" + metric("unpoller_site_latency_seconds") + ")",
			Legend:     "{{site_name}}", Unit: units.Seconds, DataSource: datasource,
			Thresholds: warningCriticalThresholds(0.05, 0.1),
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[3].ID, Grid: summary[3].Grid, Title: "WAN Uptime",
			Expression: "max by (wan_name) (" + metric("unpoller_wan_uptime_percentage") + ")",
			Legend:     "{{wan_name}}", Unit: units.Percent, DataSource: datasource,
			Thresholds: absoluteThresholds(
				dashboard.Threshold{Color: "red", Value: nil},
				dashboard.Threshold{Color: "orange", Value: ptr(99.0)},
				dashboard.Threshold{Color: "green", Value: ptr(99.9)},
			),
		}))

	connectivity := layout.row(5, 24)[0]
	builder.WithPanel(stateTimeline(StateTimelineOptions{
		ID: connectivity.ID, Grid: connectivity.Grid, Title: "WAN Connectivity",
		Expression: "max without (status) (" + metric("unpoller_site_latency_seconds", `subsystem="www"`, `status="ok"`) +
			" >= bool 0) or max without (status) (" + metric("unpoller_site_latency_seconds", `subsystem="www"`, `status!="ok"`) + " * 0)",
		Legend: "{{site_name}}", DataSource: datasource,
	}))

	traffic := layout.row(9, 16, 8)
	builder.
		WithPanel(timeSeries(TimeseriesOptions{
			ID: traffic[0].ID, Grid: traffic[0].Grid, Title: "WAN Throughput",
			Unit: units.BitsPerSecondSI, DataSource: datasource, Min: ptr(0.0),
			Targets: []PrometheusTarget{
				{
					RefID: "A", Legend: "Download {{name}} {{port}}",
					Expression: "sum by (name, port) (" + metric("unpoller_device_wan_receive_rate_bytes") + ") * 8",
				},
				{
					RefID: "B", Legend: "Upload {{name}} {{port}}",
					Expression: "sum by (name, port) (" + metric("unpoller_device_wan_transmit_rate_bytes") + ") * 8",
				},
			},
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: traffic[1].ID, Grid: traffic[1].Grid, Title: "Transfer in Last 24 Hours",
			Unit: units.BytesIEC, DataSource: datasource,
			Targets: []PrometheusTarget{
				{
					RefID: "A", Legend: "Downloaded",
					Expression: "sum(increase(" + metric("unpoller_device_wan_receive_bytes_total") + "[24h]))",
				},
				{
					RefID: "B", Legend: "Uploaded",
					Expression: "sum(increase(" + metric("unpoller_device_wan_transmit_bytes_total") + "[24h]))",
				},
			},
		}))

	series := []struct {
		title      string
		unit       string
		thresholds *dashboard.ThresholdsConfigBuilder
		targets    []PrometheusTarget
	}{
		{
			title: "WAN Latency", unit: units.Seconds, thresholds: warningCriticalThresholds(0.05, 0.1),
			targets: []PrometheusTarget{{
				RefID: "A", Legend: "{{site_name}}",
				Expression: "max by (site_name) (" + metric("unpoller_site_latency_seconds") + ")",
			}},
		},
		{
			title: "Gateway Utilization", unit: units.PercentUnit, thresholds: warningCriticalThresholds(0.75, 0.9),
			targets: []PrometheusTarget{
				{RefID: "A", Legend: "CPU {{name}}", Expression: "max by (name) (" + metric("unpoller_device_cpu_utilization_ratio") + ")"},
				{RefID: "B", Legend: "Memory {{name}}", Expression: "max by (name) (" + metric("unpoller_device_memory_utilization_ratio") + ")"},
			},
		},
		{
			title: "Gateway Temperature", unit: units.Celsius, thresholds: warningCriticalThresholds(70, 85),
			targets: []PrometheusTarget{{
				RefID: "A", Legend: "{{name}} {{temp_area}} {{temp_type}}",
				Expression: "max by (name, temp_area, temp_type) (" + metric("unpoller_device_temperature_celsius") + ")",
			}},
		},
		{
			title: "Connected Clients", unit: units.Short,
			targets: []PrometheusTarget{
				{RefID: "A", Legend: "Users {{site_name}}", Expression: "max by (site_name) (" + metric("unpoller_site_users") + ")"},
				{RefID: "B", Legend: "Guests {{site_name}}", Expression: "max by (site_name) (" + metric("unpoller_site_guests") + ")"},
				{RefID: "C", Legend: "IoT {{site_name}}", Expression: "max by (site_name) (" + metric("unpoller_site_iots") + ")"},
			},
		},
	}
	for offset := 0; offset < len(series); offset += 2 {
		placements := layout.row(8, 12, 12)
		for index, placement := range placements {
			definition := series[offset+index]
			builder.WithPanel(timeSeries(TimeseriesOptions{
				ID: placement.ID, Grid: placement.Grid, Title: definition.title,
				Unit: definition.unit, DataSource: datasource, Thresholds: definition.thresholds,
				Targets: definition.targets,
			}))
		}
	}

	return builder.Build()
}

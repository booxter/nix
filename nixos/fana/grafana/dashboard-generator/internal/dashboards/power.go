package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func PowerOverview(config Config) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	nut := func(name string, matchers ...string) string {
		return profileMetric(name, "power", append([]string{`component="nut"`, `ups=~".+"`}, matchers...)...)
	}
	summary := layout.row(5, 6, 6, 6, 6)
	builder := newDashboard(DashboardOptions{
		Title: "Power", UID: "fana-ups-overview", Tags: []string{"power", "ups"},
		From: "now-24h", Refresh: "30s",
	}).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[0].ID, Grid: summary[0].Grid, Title: "UPSes Online",
			Expression: "sum(" + nut("network_ups_tools_ups_status", `flag="OL"`) + ")",
			Legend:     "online", Unit: units.Short, DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[1].ID, Grid: summary[1].Grid, Title: "UPSes On Battery",
			Expression: "sum(" + nut("network_ups_tools_ups_status", `flag="OB"`) + ")",
			Legend:     "on battery", Unit: units.Short, DataSource: datasource,
			Thresholds: greenToRedThreshold(1),
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[2].ID, Grid: summary[2].Grid, Title: "Lowest Battery Charge",
			Expression: "min(" + nut("network_ups_tools_battery_charge") + ")",
			Legend:     "{{ups}}", Unit: units.Percent, DataSource: datasource,
			Thresholds: absoluteThresholds(
				dashboard.Threshold{Color: "red", Value: nil},
				dashboard.Threshold{Color: "orange", Value: ptr(30.0)},
				dashboard.Threshold{Color: "green", Value: ptr(50.0)},
			),
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[3].ID, Grid: summary[3].Grid, Title: "Shortest Runtime",
			Expression: "min(" + nut("network_ups_tools_battery_runtime") + ") / 60",
			Legend:     "{{ups}}", Unit: units.Minutes, DataSource: datasource,
			Thresholds: absoluteThresholds(
				dashboard.Threshold{Color: "red", Value: nil},
				dashboard.Threshold{Color: "orange", Value: ptr(10.0)},
				dashboard.Threshold{Color: "green", Value: ptr(20.0)},
			),
		}))

	series := []struct {
		title      string
		expression string
		unit       string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{
			title: "Battery Charge", expression: nut("network_ups_tools_battery_charge"), unit: units.Percent,
			thresholds: absoluteThresholds(
				dashboard.Threshold{Color: "red", Value: nil},
				dashboard.Threshold{Color: "orange", Value: ptr(30.0)},
				dashboard.Threshold{Color: "green", Value: ptr(50.0)},
			),
		},
		{title: "Battery Runtime", expression: nut("network_ups_tools_battery_runtime") + " / 60", unit: units.Minutes},
		{
			title: "UPS Load", expression: nut("network_ups_tools_ups_load"), unit: units.Percent,
			thresholds: warningCriticalThresholds(70, 90),
		},
		{title: "Input Voltage", expression: nut("network_ups_tools_input_voltage"), unit: units.Volt},
	}
	for offset := 0; offset < len(series); offset += 2 {
		placements := layout.row(8, 12, 12)
		for index, placement := range placements {
			definition := series[offset+index]
			builder.WithPanel(timeSeries(TimeseriesOptions{
				ID: placement.ID, Grid: placement.Grid, Title: definition.title,
				Unit: definition.unit, DataSource: datasource, Thresholds: definition.thresholds,
				Targets: []PrometheusTarget{{
					RefID: "A", Expression: definition.expression, Legend: "{{instance}} / {{ups}}",
				}},
			}))
		}
	}
	darwin := layout.row(8, 24)[0]
	builder.WithPanel(timeSeries(TimeseriesOptions{
		ID: darwin.ID, Grid: darwin.Grid, Title: "Darwin Power",
		Unit: units.Watt, DataSource: datasource, Min: ptr(0.0),
		Targets: []PrometheusTarget{{
			RefID: "A", Legend: "{{instance}}",
			Expression: `sum by(instance) (avg_over_time((` + freshDarwinThermalMetric("host_observability_darwin_power_watts") + `)[20m:30s]))`,
		}},
	}))
	flags := layout.row(10, 24)[0]
	builder.WithPanel(metricTable(MetricTableOptions{
		ID: flags.ID, Grid: flags.Grid, Title: "Current UPS Flags", Unit: units.Short,
		Expression: nut("network_ups_tools_ups_status", `flag=~"OL|OB|LB|CHRG|DISCHRG"`),
		DataSource: datasource,
	}))

	return builder.Build()
}

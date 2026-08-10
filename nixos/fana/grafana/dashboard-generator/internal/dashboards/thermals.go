package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func thermalCPU(matchers ...string) string {
	thermalZoneMatchers := append(append([]string{}, matchers...), `type=~"cpu-thermal|x86_pkg_temp"`)
	hwmonMatchers := append(append([]string{}, matchers...),
		`chip=~"platform_coretemp_0|pci0000:00_0000:00:18_3"`, `sensor="temp1"`)
	darwinMatchers := append(append([]string{}, matchers...), `group="cpu"`)
	return `max by(instance) (` + nodeMetric("node_thermal_zone_temp", thermalZoneMatchers...) + ` or ` +
		nodeMetric("node_hwmon_temp_celsius", hwmonMatchers...) + ` or ` +
		nodeMetric("host_observability_darwin_temperature_group_max_celsius", darwinMatchers...) + `)`
}

func thermalStorage() string {
	return `max by(instance) (` + nodeMetric("node_hwmon_temp_celsius", `chip=~"nvme_.*"`, `sensor="temp1"`) +
		` or ` + nodeMetric("host_observability_hba_temperature_celsius", `sensor="roc"`) +
		` or ` + nodeMetric("host_observability_darwin_temperature_group_max_celsius", `group="storage"`) + `)`
}

func ThermalsOverview(config Config) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	summary := layout.row(5, 5, 5, 5, 4, 5)
	hddMetric := `smartctl_device_temperature{scrape_profile="hardware",component="smartctl",temperature_type="current"}`

	builder := newDashboard(DashboardOptions{
		Title: "Thermals", UID: "fana-hardware-thermals", Tags: []string{"hardware", "thermals"},
		From: "now-24h", Refresh: "30s",
	}).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[0].ID, Grid: summary[0].Grid, Title: "Hottest Hypervisor CPU / Package",
			Expression: `topk(1, avg_over_time((` + thermalCPU(`host_hypervisor="true"`) + `)[2m:30s]))`,
			Legend:     "{{instance}}", Unit: units.Celsius, DataSource: datasource,
			Thresholds: warningCriticalThresholds(80, 85),
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[1].ID, Grid: summary[1].Grid, Title: "Hottest Other CPU / Package",
			Expression: `topk(1, avg_over_time((` + thermalCPU(`host_hypervisor="false"`) + `)[2m:30s]))`,
			Legend:     "{{instance}}", Unit: units.Celsius, DataSource: datasource,
			Thresholds: warningCriticalThresholds(60, 75),
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[2].ID, Grid: summary[2].Grid, Title: "Hottest Storage Sensor",
			Expression: `topk(1, ` + thermalStorage() + `)`, Legend: "{{instance}}",
			Unit: units.Celsius, DataSource: datasource, Thresholds: warningCriticalThresholds(50, 65),
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[3].ID, Grid: summary[3].Grid, Title: "Hottest HDD",
			Expression: `topk(1, max by(instance, device) (` + hddMetric + `))`, Legend: "{{instance}} / {{device}}",
			Unit: units.Celsius, DataSource: datasource, Thresholds: warningCriticalThresholds(45, 50),
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[4].ID, Grid: summary[4].Grid, Title: "Darwin Thermal Warning Status",
			Unit: units.Short, DataSource: datasource, Min: ptr(0.0), Max: ptr(2.0), Background: true,
			Thresholds: warningCriticalThresholds(1, 2),
			Targets: []PrometheusTarget{
				{RefID: "A", Expression: nodeMetric("host_observability_darwin_thermal_warning_level"), Legend: "{{instance}} thermal"},
				{RefID: "B", Expression: nodeMetric("host_observability_darwin_performance_warning_level"), Legend: "{{instance}} performance"},
			},
		}))

	series := []struct {
		title      string
		expression string
		legend     string
		unit       string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{
			title: "CPU / Package Temperature", unit: units.Celsius, legend: "{{instance}}",
			expression: `avg_over_time((` + thermalCPU() + `)[5m:30s])`,
		},
		{
			title: "Hottest Exposed Sensor By Host", unit: units.Celsius, legend: "{{instance}}",
			expression: `avg_over_time((max by(instance) (` + nodeMetric("node_hwmon_temp_celsius") + ` or ` +
				nodeMetric("host_observability_hba_temperature_celsius", `sensor="roc"`) + ` or ` +
				nodeMetric("host_observability_darwin_temperature_max_celsius") + `))[5m:30s])`,
			thresholds: warningCriticalThresholds(60, 75),
		},
		{
			title: "Storage Temperature", unit: units.Celsius, legend: "{{instance}}",
			expression: thermalStorage(), thresholds: warningCriticalThresholds(60, 75),
		},
		{
			title: "Fan RPM", unit: units.RevolutionsPerMinute, legend: "{{instance}} / {{sensor}}",
			expression: nodeMetric("node_hwmon_fan_rpm"), thresholds: redToGreenThreshold(1),
		},
		{
			title: "HDD Temperatures", unit: units.Celsius, legend: "{{instance}} / {{device}}",
			expression: hddMetric, thresholds: warningCriticalThresholds(45, 50),
		},
		{
			title: "HBA Temperature", unit: units.Celsius, legend: "{{instance}} HBA / ROC {{controller}}",
			expression: nodeMetric("host_observability_hba_temperature_celsius", `sensor="roc"`),
			thresholds: warningCriticalThresholds(60, 75),
		},
	}
	for offset := 0; offset < len(series); offset += 2 {
		placements := layout.row(8, 12, 12)
		for index, placement := range placements {
			definition := series[offset+index]
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

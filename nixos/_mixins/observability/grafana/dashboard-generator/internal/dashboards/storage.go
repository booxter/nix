package dashboards

import (
	"fmt"

	"github.com/grafana/grafana-foundation-sdk/go/common"
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func StorageOverview(config Config) (dashboard.Dashboard, error) {
	storageHost, err := config.diskBayHost()
	if err != nil {
		return dashboard.Dashboard{}, err
	}

	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	node := func(name string, matchers ...string) string {
		return nodeMetric(name, append([]string{fmt.Sprintf("instance=%q", storageHost.Name)}, matchers...)...)
	}
	smart := func(name string, matchers ...string) string {
		labels := []string{`component="smartctl"`, fmt.Sprintf("instance=%q", storageHost.Name)}
		return profileMetric(name, "hardware", append(labels, matchers...)...)
	}
	bayInfo := node("host_observability_disk_bay_info")
	withBay := func(metric string) string {
		return metric + " * on(instance,device) group_left(bay) max by(instance,device,bay) (" + bayInfo + ")"
	}

	builder := newDashboard(DashboardOptions{
		Title: "NAS / Storage", UID: "nas-beast", Tags: []string{"nas", "storage", "raid", "smart"},
		From: "now-24h", Refresh: "30s",
	})

	summary := layout.row(5, 4, 4, 4, 4, 4, 4)
	statDefinitions := []struct {
		title      string
		expression string
		legend     string
		unit       string
		thresholds *dashboard.ThresholdsConfigBuilder
		textMode   common.BigValueTextMode
	}{
		{
			title: "RAID Missing Members", expression: "max(" + node("host_observability_md_degraded") + ") or vector(0)",
			legend: "missing", unit: units.Short, thresholds: greenToRedThreshold(1),
		},
		{
			title: "RAID Action", expression: node("host_observability_md_sync_action_info"),
			legend: "{{device}} / {{action_title}}", unit: units.Short, textMode: common.BigValueTextModeName,
		},
		{
			title: "RAID Progress",
			expression: "min(" + node("host_observability_md_sync_progress_percent") +
				" + 100 * (1 - " + node("host_observability_md_sync_active") + ")) or vector(100)",
			legend: "progress", unit: units.Percent,
			thresholds: absoluteThresholds(
				dashboard.Threshold{Color: "orange", Value: nil},
				dashboard.Threshold{Color: "green", Value: ptr(100.0)},
			),
		},
		{
			title: "RAID ETA", expression: "max(" + node("host_observability_md_sync_eta_seconds") + ") / 3600",
			legend: "ETA", unit: units.Hours,
		},
		{
			title: "RAID Speed", expression: "max(" + node("host_observability_md_sync_speed_bytes_per_second") + ")",
			legend: "speed", unit: units.BytesPerSecondSI,
		},
		{
			title: "Btrfs Filesystem Used",
			expression: "100 * (1 - " + node("node_filesystem_avail_bytes", `fstype="btrfs"`) +
				" / " + node("node_filesystem_size_bytes", `fstype="btrfs"`) + ")",
			legend: "{{mountpoint}}", unit: units.Percent, thresholds: warningCriticalThresholds(75, 90),
		},
	}
	for index, definition := range statDefinitions {
		placement := summary[index]
		builder.WithPanel(valueStat(ValueStatOptions{
			ID: placement.ID, Grid: placement.Grid, Title: definition.title,
			Expression: definition.expression, Legend: definition.legend, Unit: definition.unit,
			DataSource: datasource, Thresholds: definition.thresholds, TextMode: definition.textMode,
		}))
	}

	bayLayout := storageHost.DiskBays
	if bayLayout == nil {
		return dashboard.Dashboard{}, fmt.Errorf("storage host %q lacks a disk-bay layout", storageHost.Name)
	}
	bayHeaders := []panelPlacement{
		layout.place(0, 0, 12, 1),
		layout.place(12, 0, 12, 1),
	}
	builder.
		WithPanel(valueStat(ValueStatOptions{
			ID: bayHeaders[0].ID, Grid: bayHeaders[0].Grid,
			Expression: "max(" + smart("smartctl_device_temperature", `temperature_type="current"`) + ")",
			Legend:     "Temperature", Unit: units.Celsius, DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: bayHeaders[1].ID, Grid: bayHeaders[1].Grid,
			Expression: "min(" + smart("smartctl_device_smart_status") + ")",
			Legend:     "SMART", Unit: units.Short, DataSource: datasource,
		}))
	bayWidth := uint32(12 / bayLayout.Columns)
	for column := 0; column < bayLayout.Columns; column++ {
		for row := 0; row < bayLayout.Rows; row++ {
			bay := column*bayLayout.Rows + row + 1
			bayMatcher := fmt.Sprintf("bay=%q", fmt.Sprint(bay))
			bayJoin := node("host_observability_disk_bay_info", bayMatcher)
			joinBay := func(metric string) string {
				return metric + " * on(instance,device) group_left(bay) max by(instance,device,bay) (" + bayJoin + ")"
			}
			y := uint32(1 + row*2)
			temperature := layout.place(uint32(column)*bayWidth, y, bayWidth, 2)
			status := layout.place(12+uint32(column)*bayWidth, y, bayWidth, 2)
			builder.
				WithPanel(valueStat(ValueStatOptions{
					ID: temperature.ID, Grid: temperature.Grid, Title: fmt.Sprint(bay),
					Expression: "max(" + joinBay(smart(
						"smartctl_device_temperature", `temperature_type="current"`, `device=~"sd[a-z]+"`,
					)) + ") or vector(-1)",
					Unit: units.Celsius, DataSource: datasource, Background: true,
					Thresholds: absoluteThresholds(
						dashboard.Threshold{Color: "gray", Value: nil},
						dashboard.Threshold{Color: "green", Value: ptr(0.0)},
						dashboard.Threshold{Color: "orange", Value: ptr(45.0)},
						dashboard.Threshold{Color: "red", Value: ptr(50.0)},
					),
					Mappings: []dashboard.ValueMapping{exactValueMapping(map[string]dashboard.ValueMappingResult{
						"-1": mappedValue("Empty", "gray", 0),
					})},
				})).
				WithPanel(valueStat(ValueStatOptions{
					ID: status.ID, Grid: status.Grid, Title: fmt.Sprint(bay),
					Expression: "max(" + joinBay(smart(
						"smartctl_device_smart_status", `device=~"sd[a-z]+"`,
					)) + ") or vector(-1)",
					Unit: units.Short, DataSource: datasource, Background: true,
					Thresholds: absoluteThresholds(
						dashboard.Threshold{Color: "gray", Value: nil},
						dashboard.Threshold{Color: "red", Value: ptr(0.0)},
						dashboard.Threshold{Color: "green", Value: ptr(1.0)},
					),
					Mappings: []dashboard.ValueMapping{exactValueMapping(map[string]dashboard.ValueMappingResult{
						"-1": mappedValue("Empty", "gray", 0),
						"0":  mappedValue("Fail", "red", 1),
						"1":  mappedValue("OK", "green", 2),
					})},
				}))
		}
	}
	layout.advance(uint32(1 + bayLayout.Rows*2))

	diskSeries := []struct {
		title      string
		expression string
		legend     string
		unit       string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{
			title: "Disk Temperature History", unit: units.Celsius, legend: "Bay {{bay}} ({{device}})",
			expression: withBay(smart("smartctl_device_temperature", `temperature_type="current"`, `device=~"sd[a-z]+"`)),
			thresholds: warningCriticalThresholds(50, 55),
		},
		{
			title: "Btrfs Device Errors", unit: units.Short, legend: "{{type}}",
			expression: "sum by(type) (" + node("node_btrfs_device_errors_total") + ")",
		},
		{
			title: "Btrfs Used Bytes", unit: units.BytesIEC, legend: "{{block_group_type}}",
			expression: "sum by(block_group_type) (" + node("node_btrfs_used_bytes") + ")",
		},
		{
			title: "Disk Read Throughput", unit: units.BytesPerSecondSI, legend: "{{device}}",
			expression: "sum by(device) (rate(" + node("node_disk_read_bytes_total", `device=~"sd[a-z]+"`) +
				"[5m]) and on(instance,device) " + smart("smartctl_device_smart_status") + ")",
		},
		{
			title: "Disk Write Throughput", unit: units.BytesPerSecondSI, legend: "{{device}}",
			expression: "sum by(device) (rate(" + node("node_disk_written_bytes_total", `device=~"sd[a-z]+"`) +
				"[5m]) and on(instance,device) " + smart("smartctl_device_smart_status") + ")",
		},
		{
			title: "Disk Total Throughput", unit: units.BytesPerSecondSI, legend: "{{device}}",
			expression: "sum by(device) ((rate(" + node("node_disk_read_bytes_total", `device=~"sd[a-z]+"`) +
				"[5m]) + rate(" + node("node_disk_written_bytes_total", `device=~"sd[a-z]+"`) +
				"[5m])) and on(instance,device) " + smart("smartctl_device_smart_status") + ")",
		},
	}
	for offset := 0; offset < len(diskSeries); offset += 3 {
		placements := layout.row(8, 8, 8, 8)
		for index, placement := range placements {
			definition := diskSeries[offset+index]
			builder.WithPanel(timeSeries(TimeseriesOptions{
				ID: placement.ID, Grid: placement.Grid, Title: definition.title,
				Unit: definition.unit, DataSource: datasource, Min: ptr(0.0),
				Thresholds: definition.thresholds,
				Targets: []PrometheusTarget{{
					RefID: "A", Expression: definition.expression, Legend: definition.legend,
				}},
			}))
		}
	}

	thermal := layout.row(8, 12, 12)
	builder.
		WithPanel(timeSeries(TimeseriesOptions{
			ID: thermal[0].ID, Grid: thermal[0].Grid, Title: "HBA Temperature",
			Unit: units.Celsius, DataSource: datasource, Min: ptr(0.0),
			Thresholds: warningCriticalThresholds(60, 75),
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: "max by(controller,sensor) (" +
					node("host_observability_hba_temperature_celsius", `sensor="roc"`) + ")",
				Legend: "HBA / ROC {{controller}}",
			}},
		})).
		WithPanel(timeSeries(TimeseriesOptions{
			ID: thermal[1].ID, Grid: thermal[1].Grid, Title: "CPU Package Temperature",
			Unit: units.Celsius, DataSource: datasource, Min: ptr(0.0),
			Thresholds: warningCriticalThresholds(60, 75),
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: "max by(chip,sensor) (" + node(
					"node_hwmon_temp_celsius", `chip="platform_coretemp_0"`, `sensor="temp1"`,
				) + ")", Legend: "Linux coretemp / Package id 0",
			}},
		}))

	psu := func(name, sensorMatcher, labelMatcher string) string {
		return "max by(instance,chip,sensor) (" + node(name, sensorMatcher) +
			") * on(instance,chip,sensor) group_left(label) max by(instance,chip,sensor,label) (" +
			node("node_hwmon_sensor_label", labelMatcher) +
			") * on(instance,chip) group_left() max by(instance,chip) (" +
			node("node_hwmon_chip_names", `chip_name="corsairpsu"`) + ")"
	}
	psuSeries := []struct {
		title      string
		expression string
		unit       string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{title: "PSU Power", expression: psu("node_hwmon_power_watt", `sensor=~"power[1-4]"`, `label=~".+"`), unit: units.Watt},
		{title: "PSU Output Rails", expression: psu("node_hwmon_in_volts", `sensor=~"in[123]"`, `label=~".+"`), unit: units.Volt},
		{title: "PSU Rail Current", expression: psu("node_hwmon_curr_amps", `sensor=~"curr[234]"`, `label=~".+"`), unit: units.Ampere},
		{
			title: "PSU Temperatures", expression: psu("node_hwmon_temp_celsius", `sensor=~"temp[0-9]+"`, `label=~"vrm temp|case temp"`),
			unit: units.Celsius, thresholds: warningCriticalThresholds(55, 65),
		},
		{title: "PSU Fan RPM", expression: psu("node_hwmon_fan_rpm", `sensor=~"fan[0-9]+"`, `label="psu fan"`), unit: units.RevolutionsPerMinute},
		{title: "PSU Input Voltage", expression: psu("node_hwmon_in_volts", `sensor=~"in[0-9]+"`, `label="v_in"`), unit: units.Volt},
	}
	for offset := 0; offset < len(psuSeries); offset += 2 {
		placements := layout.row(8, 12, 12)
		for index, placement := range placements {
			definition := psuSeries[offset+index]
			builder.WithPanel(timeSeries(TimeseriesOptions{
				ID: placement.ID, Grid: placement.Grid, Title: definition.title,
				Unit: definition.unit, DataSource: datasource, Min: ptr(0.0),
				Thresholds: definition.thresholds,
				Targets: []PrometheusTarget{{
					RefID: "A", Expression: definition.expression, Legend: "{{label}}",
				}},
			}))
		}
	}

	smartAttributes := []struct {
		title      string
		attribute  string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{title: "SMART Reallocated Sectors", attribute: "Reallocated_Sector_Ct", thresholds: warningCriticalThresholds(1, 10)},
		{title: "SMART Pending Sectors", attribute: "Current_Pending_Sector", thresholds: greenToRedThreshold(1)},
		{title: "SMART Offline Uncorrectable", attribute: "Offline_Uncorrectable", thresholds: greenToRedThreshold(1)},
		{title: "SMART Reported Uncorrectable", attribute: "Reported_Uncorrect", thresholds: greenToRedThreshold(1)},
	}
	for offset := 0; offset < len(smartAttributes); offset += 2 {
		placements := layout.row(8, 12, 12)
		for index, placement := range placements {
			definition := smartAttributes[offset+index]
			expression := "max by(instance,bay,device) (" + withBay(smart(
				"smartctl_device_attribute", `device=~"sd[a-z]+"`,
				fmt.Sprintf("attribute_name=%q", definition.attribute), `attribute_value_type="raw"`,
			)) + ")"
			builder.WithPanel(metricTable(MetricTableOptions{
				ID: placement.ID, Grid: placement.Grid, Title: definition.title,
				Expression: expression, Unit: units.Short, DataSource: datasource,
				Thresholds: definition.thresholds, DisplayMode: common.TableCellDisplayModeColorText,
			}))
		}
	}

	return builder.Build()
}

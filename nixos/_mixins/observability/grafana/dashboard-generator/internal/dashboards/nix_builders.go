package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func NixBuildersOverview(config Config) (dashboard.Dashboard, error) {
	prometheusDatasource := config.DataSources.Prometheus.reference()
	lokiDatasource := config.DataSources.Loki.reference()
	layout := newPanelLayout()
	builder := func(metric string, matchers ...string) string {
		return nodeMetric(metric, append([]string{`host_builder="true"`}, matchers...)...)
	}

	memoryUsed := `100 * ((1 - (` + builder("node_memory_MemAvailable_bytes") + ` / ` +
		builder("node_memory_MemTotal_bytes") + `)) or (1 - ((` + builder("node_memory_free_bytes") + ` + ` +
		builder("node_memory_inactive_bytes") + `) / ` + builder("node_memory_total_bytes") + `)))`
	rootUsed := `100 * (1 - (` + builder("node_filesystem_avail_bytes", `mountpoint="/"`, `fstype!=""`) +
		` / ` + builder("node_filesystem_size_bytes", `mountpoint="/"`, `fstype!=""`) + `))`
	daemonActive := `max by(instance) (` + builder("node_systemd_unit_state", `name="nix-daemon.service"`, `state="active"`) +
		` or ` + builder("host_observability_darwin_launchd_job_running", `domain="system"`, `name="nix-daemon"`) + `)`

	summary := layout.row(5, 6, 6, 6, 6)
	model := newDashboard(DashboardOptions{
		Title: "Nix Builders", UID: "fana-nix-builders", Tags: []string{"nix", "builders", "fleet"},
		From: "now-24h", Refresh: "30s",
	}).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[0].ID, Grid: summary[0].Grid, Title: "Builders Up",
			Expression: `sum(` + builder("up") + `)`, Legend: "up", Unit: units.Short,
			DataSource: prometheusDatasource, Min: ptr(0.0), Thresholds: redToGreenThreshold(1),
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[1].ID, Grid: summary[1].Grid, Title: "Nix Daemons Active",
			Expression: `sum(` + daemonActive + `)`, Legend: "active", Unit: units.Short,
			DataSource: prometheusDatasource, Min: ptr(0.0), Thresholds: redToGreenThreshold(1),
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[2].ID, Grid: summary[2].Grid, Title: "Warmer Targets Healthy",
			Expression: `sum(` + builder("host_observability_nixpkgs_cache_warmer_last_attempt_success") + `)`,
			Legend:     "healthy", Unit: units.Short, DataSource: prometheusDatasource, Min: ptr(0.0),
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[3].ID, Grid: summary[3].Grid, Title: "Oldest Warmer Success",
			Expression: `max(time() - ` + builder("host_observability_nixpkgs_cache_warmer_last_success_timestamp_seconds") + `)`,
			Legend:     "oldest", Unit: units.DurationInDaysHoursMinutesSeconds, DataSource: prometheusDatasource,
			Min: ptr(0.0), Thresholds: warningCriticalThresholds(86400, 129600),
		}))

	resources := []struct {
		title      string
		expression string
		legend     string
		unit       string
		min        *float64
		max        *float64
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{
			title: "CPU Busy", unit: units.Percent, legend: "{{instance}}",
			expression: `100 - (avg by(instance) (rate(` + builder("node_cpu_seconds_total", `mode="idle"`) + `[$__rate_interval])) * 100)`,
			min:        ptr(0.0), max: ptr(100.0), thresholds: warningCriticalThresholds(70, 90),
		},
		{
			title: "Memory Used", unit: units.Percent, legend: "{{instance}}", expression: memoryUsed,
			min: ptr(0.0), max: ptr(100.0), thresholds: warningCriticalThresholds(75, 90),
		},
		{
			title: "CPU Pressure", unit: units.Percent, legend: "{{instance}}",
			expression: `100 * rate(` + builder("node_pressure_cpu_waiting_seconds_total") + `[$__rate_interval])`,
			min:        ptr(0.0), thresholds: warningCriticalThresholds(70, 90),
		},
		{
			title: "Memory And I/O Pressure", unit: units.Percent, legend: "{{instance}} {{__name__}}",
			expression: `100 * rate({__name__=~"node_pressure_(memory|io)_stalled_seconds_total",scrape_profile="node",host_builder="true"}[$__rate_interval])`,
			min:        ptr(0.0), thresholds: warningCriticalThresholds(10, 50),
		},
		{
			title: "Root Filesystem Used", unit: units.Percent, legend: "{{instance}}", expression: rootUsed,
			min: ptr(0.0), max: ptr(100.0), thresholds: warningCriticalThresholds(85, 95),
		},
		{
			title: "Root Inodes Used", unit: units.Percent, legend: "{{instance}}",
			expression: `100 * (1 - (` + builder("node_filesystem_files_free", `mountpoint="/"`, `fstype!=""`) +
				` / ` + builder("node_filesystem_files", `mountpoint="/"`, `fstype!=""`) + `))`,
			min: ptr(0.0), max: ptr(100.0), thresholds: warningCriticalThresholds(85, 95),
		},
		{
			title: "Disk Throughput", unit: units.BytesPerSecondSI, legend: "{{instance}}",
			expression: `sum by(instance) (rate(` + builder("node_disk_read_bytes_total", `device!~"loop.*|ram.*"`) + `[$__rate_interval]) + rate(` +
				builder("node_disk_written_bytes_total", `device!~"loop.*|ram.*"`) + `[$__rate_interval]))`, min: ptr(0.0),
		},
		{
			title: "Network Throughput", unit: units.BitsPerSecondSI, legend: "{{instance}}",
			expression: `sum by(instance) (rate(` + builder("node_network_receive_bytes_total", `device!~"`+physicalInterfaceExclusion+`"`) +
				`[$__rate_interval]) + rate(` + builder("node_network_transmit_bytes_total", `device!~"`+physicalInterfaceExclusion+`"`) + `[$__rate_interval])) * 8`,
			min: ptr(0.0),
		},
	}
	for offset := 0; offset < len(resources); offset += 2 {
		placements := layout.row(8, 12, 12)
		for index, placement := range placements {
			definition := resources[offset+index]
			model.WithPanel(timeSeries(TimeseriesOptions{
				ID: placement.ID, Grid: placement.Grid, Title: definition.title,
				Unit: definition.unit, DataSource: prometheusDatasource, Min: definition.min,
				Max: definition.max, Thresholds: definition.thresholds,
				Targets: []PrometheusTarget{{RefID: "A", Expression: definition.expression, Legend: definition.legend}},
			}))
		}
	}

	warmer := layout.row(8, 12, 12)
	model.
		WithPanel(stateTimeline(StateTimelineOptions{
			ID: warmer[0].ID, Grid: warmer[0].Grid, Title: "Nixpkgs Warmer Outcomes",
			Expression: builder("host_observability_nixpkgs_cache_warmer_last_attempt_success"),
			Legend:     "{{instance}} {{branch}} {{system}}", DataSource: prometheusDatasource,
		})).
		WithPanel(timeSeries(TimeseriesOptions{
			ID: warmer[1].ID, Grid: warmer[1].Grid, Title: "Nixpkgs Warmer Success Age",
			Unit: units.DurationInDaysHoursMinutesSeconds, DataSource: prometheusDatasource, Min: ptr(0.0),
			Thresholds: warningCriticalThresholds(86400, 129600), ShowThresholds: true,
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: `time() - ` + builder("host_observability_nixpkgs_cache_warmer_last_success_timestamp_seconds"),
				Legend: "{{instance}} {{branch}} {{system}}",
			}},
		}))

	packageOutcomes := layout.row(8, 24)[0]
	model.WithPanel(timeSeries(TimeseriesOptions{
		ID: packageOutcomes.ID, Grid: packageOutcomes.Grid, Title: "Nixpkgs Warmer Package Outcomes",
		Unit: units.Short, DataSource: prometheusDatasource, Min: ptr(0.0),
		Targets: []PrometheusTarget{
			{
				RefID: "A", Expression: builder("host_observability_nixpkgs_cache_warmer_last_attempt_selected_packages"),
				Legend: "{{branch}} {{system}} selected",
			},
			{
				RefID: "B", Expression: builder("host_observability_nixpkgs_cache_warmer_last_attempt_built_packages"),
				Legend: "{{branch}} {{system}} built",
			},
			{
				RefID: "C", Expression: builder("host_observability_nixpkgs_cache_warmer_last_attempt_failed_packages"),
				Legend: "{{branch}} {{system}} failed",
			},
		},
	}))

	fleetWarmer := layout.row(5, 6, 6, 6, 6)
	model.
		WithPanel(valueStat(ValueStatOptions{
			ID: fleetWarmer[0].ID, Grid: fleetWarmer[0].Grid, Title: "Fleet Warmer Running",
			Expression: builder("host_observability_fleet_cache_warmer_running"),
			Legend: "{{instance}}", Unit: units.Short, DataSource: prometheusDatasource,
			Min: ptr(0.0), Max: ptr(1.0), Background: true,
			Mappings: []dashboard.ValueMapping{exactValueMapping(map[string]dashboard.ValueMappingResult{
				"0": mappedValue("Idle", "green", 0),
				"1": mappedValue("Running", "blue", 1),
			})},
		})).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: fleetWarmer[1].ID, Grid: fleetWarmer[1].Grid, Title: "Fleet Warmer Last Attempt",
			Expression: builder("host_observability_fleet_cache_warmer_last_attempt_success"),
			Legend: "{{instance}}", DataSource: prometheusDatasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: fleetWarmer[2].ID, Grid: fleetWarmer[2].Grid, Title: "Fleet Warmer Duration",
			Expression: builder("host_observability_fleet_cache_warmer_last_attempt_duration_seconds"),
			Legend: "{{instance}}", Unit: units.DurationInDaysHoursMinutesSeconds,
			DataSource: prometheusDatasource, Min: ptr(0.0),
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: fleetWarmer[3].ID, Grid: fleetWarmer[3].Grid, Title: "Fleet Output Paths",
			Expression: builder("host_observability_fleet_cache_warmer_output_paths"),
			Legend: "{{instance}}", Unit: units.Short, DataSource: prometheusDatasource, Min: ptr(0.0),
		}))

	logs := layout.row(12, 24)[0]
	model.WithPanel(logsPanel(logs.ID, "Recent Nix And Warmer Logs",
		`{job="systemd-journal",systemd_unit="nix-daemon.service"} or {job="darwin-file-log",service_name=~"nix-daemon|nixpkgs-cache-warmer|fleet-cache-warmer"}`,
		logs.Grid, lokiDatasource))

	return model.Build()
}

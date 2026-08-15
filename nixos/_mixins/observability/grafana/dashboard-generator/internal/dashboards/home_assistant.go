package dashboards

import (
	"fmt"

	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

const homeAssistantService = "home"

func HomeAssistantOverview(config Config) (dashboard.Dashboard, error) {
	owner, err := config.serviceHost(homeAssistantService)
	if err != nil {
		return dashboard.Dashboard{}, err
	}
	prometheusDatasource := config.DataSources.Prometheus.reference()
	lokiDatasource := config.DataSources.Loki.reference()
	layout := newPanelLayout()
	stats := layout.row(4, 4, 4, 4, 4, 4, 4)
	application := func(metric string, matchers ...string) string {
		return applicationMetric(metric, homeAssistantService, matchers...)
	}
	node := func(metric string, matchers ...string) string {
		return nodeMetric(metric, append([]string{fmt.Sprintf(`instance=%q`, owner)}, matchers...)...)
	}

	builder := newDashboard(DashboardOptions{
		Title: "Home Assistant", UID: "home-assistant", Tags: []string{"home-assistant"},
		From: "now-24h", Refresh: "30s",
	}).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: stats[0].ID, Grid: stats[0].Grid, Title: "Metrics",
			Expression: "max(" + application("up") + ")", Legend: "metrics", DataSource: prometheusDatasource,
		})).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: stats[1].ID, Grid: stats[1].Grid, Title: "HTTPS Probe",
			Expression: `max(probe_success{probe_family="service",probe_role="frontdoor",service="home"})`,
			Legend:     "HTTPS", DataSource: prometheusDatasource,
		})).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: stats[2].ID, Grid: stats[2].Grid, Title: "Service",
			Expression: "max(" + node("node_systemd_unit_state", `name="home-assistant.service"`, `state="active"`) + ")",
			Legend:     "systemd", DataSource: prometheusDatasource,
		}))

	statDefinitions := []struct {
		title      string
		expression string
		unit       string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{
			title: "Unavailable Entities", unit: units.Short,
			expression: "sum(1 - " + application("homeassistant_entity_available") + ") or vector(0)",
			thresholds: warningCriticalThresholds(1, 5),
		},
		{
			title: "Backup Age", unit: units.Hours,
			expression: "max((time() - " + node("host_observability_backup_last_success_timestamp_seconds", `phase="local"`) +
				") / 3600) or vector(0)",
			thresholds: warningCriticalThresholds(24, 36),
		},
		{
			title: "Root Disk Used", unit: units.Percent,
			expression: "100 * (1 - (" + node("node_filesystem_avail_bytes", `mountpoint="/"`, `fstype!=""`) +
				" / " + node("node_filesystem_size_bytes", `mountpoint="/"`, `fstype!=""`) + "))",
			thresholds: warningCriticalThresholds(75, 90),
		},
	}
	for index, definition := range statDefinitions {
		placement := stats[index+3]
		builder.WithPanel(valueStat(ValueStatOptions{
			ID: placement.ID, Grid: placement.Grid, Title: definition.title,
			Expression: definition.expression, Legend: owner, Unit: definition.unit,
			DataSource: prometheusDatasource, Thresholds: definition.thresholds,
		}))
	}

	details := layout.row(8, 8, 8, 8)
	builder.
		WithPanel(timeSeries(TimeseriesOptions{
			ID: details[0].ID, Grid: details[0].Grid, Title: "Entities by Domain",
			Unit: units.Short, DataSource: prometheusDatasource, Min: ptr(0.0),
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: "count by(domain) (" + application("homeassistant_entity_available") + ")", Legend: "{{domain}}",
			}},
		})).
		WithPanel(timeSeries(TimeseriesOptions{
			ID: details[1].ID, Grid: details[1].Grid, Title: "VM Resource Use",
			Unit: units.Percent, DataSource: prometheusDatasource, Min: ptr(0.0), Max: ptr(100.0),
			Targets: []PrometheusTarget{
				{
					RefID: "A", Legend: "CPU",
					Expression: "100 * (1 - avg(rate(" + node("node_cpu_seconds_total", `mode="idle"`) + "[5m])))",
				},
				{
					RefID: "B", Legend: "Memory",
					Expression: "100 * (1 - " + node("node_memory_MemAvailable_bytes") + " / " + node("node_memory_MemTotal_bytes") + ")",
				},
			},
		})).
		WithPanel(logsPanel(details[2].ID, "Recent Errors",
			fmt.Sprintf(`{host=%q, systemd_unit="home-assistant.service"} |~ "(?i)error|exception|traceback"`, owner),
			details[2].Grid, lokiDatasource))

	return builder.Build()
}

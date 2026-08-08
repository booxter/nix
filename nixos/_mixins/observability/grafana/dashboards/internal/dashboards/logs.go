package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/common"
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	logspanel "github.com/grafana/grafana-foundation-sdk/go/logs"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func logsPanel(id uint32, title, expression string, grid dashboard.GridPos, datasource common.DataSourceRef) *logspanel.PanelBuilder {
	return logspanel.NewPanelBuilder().
		Id(id).
		Title(title).
		Datasource(datasource).
		GridPos(grid).
		ShowLabels(true).
		ShowCommonLabels(false).
		ShowTime(true).
		WrapLogMessage(true).
		EnableLogDetails(true).
		SortOrder(common.LogsSortOrderDescending).
		DedupStrategy(common.LogsDedupStrategyNone).
		WithTarget(lokiQuery("A", expression, "", datasource))
}

func LogsOverview(config Config) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Loki.reference()
	layout := newPanelLayout()
	counts := layout.row(8, 12, 12)
	recent := layout.row(12, 12, 12)
	allLinux := layout.row(12, 24)[0]
	allDarwin := layout.row(12, 24)[0]
	allLogs := `{job=~"systemd-journal|darwin-file-log"}`

	return newDashboard(DashboardOptions{
		Title: "Logs", UID: "fana-logs-overview", Tags: []string{"logs", "fleet"},
		From: "now-24h", Refresh: "30s",
	}).
		WithPanel(timeSeries(TimeseriesOptions{
			ID: counts[0].ID, Grid: counts[0].Grid, Title: "Errors By Host",
			Unit: units.Short, DataSource: datasource, Min: ptr(0.0),
			LokiTargets: []LokiTarget{{
				RefID: "A", Legend: "{{host}}",
				Expression: `sum by (host) ((count_over_time({job="systemd-journal",level=~"emerg|alert|crit|err|error"}[15m]) or count_over_time({job="darwin-file-log"} | detected_level=~"critical|error|fatal" [15m]))) or (sum by (host) (count_over_time(` + allLogs + `[15m])) * 0)`,
			}},
		})).
		WithPanel(timeSeries(TimeseriesOptions{
			ID: counts[1].ID, Grid: counts[1].Grid, Title: "Warnings By Host",
			Unit: units.Short, DataSource: datasource, Min: ptr(0.0),
			LokiTargets: []LokiTarget{{
				RefID: "A", Legend: "{{host}}",
				Expression: `sum by (host) ((count_over_time({job="systemd-journal",level="warning"}[15m]) or count_over_time({job="darwin-file-log"} | detected_level=~"warn|warning" [15m]))) or (sum by (host) (count_over_time(` + allLogs + `[15m])) * 0)`,
			}},
		})).
		WithPanel(logsPanel(recent[0].ID, "Recent Errors",
			allLogs+` | (level=~"emerg|alert|crit|err|error" or detected_level=~"critical|error|fatal")`,
			recent[0].Grid, datasource)).
		WithPanel(logsPanel(recent[1].ID, "Recent Warnings",
			allLogs+` | (level=~"warning" or detected_level=~"warn|warning")`,
			recent[1].Grid, datasource)).
		WithPanel(logsPanel(allLinux.ID, "Recent Linux Logs", `{job="systemd-journal"}`, allLinux.Grid, datasource)).
		WithPanel(logsPanel(allDarwin.ID, "Recent Darwin Logs", `{job="darwin-file-log"}`, allDarwin.Grid, datasource)).
		Build()
}

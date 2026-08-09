package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

const vikunjaService = "vikunja"

func VikunjaOverview(config Config) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	stats := layout.row(8, 6, 6, 6, 6)
	serviceMetric := func(metric string) string {
		return applicationMetric(metric, vikunjaService)
	}

	builder := newDashboard(DashboardOptions{
		Title: "Vikunja", UID: "vikunja", Tags: []string{"vikunja"},
		From: "now-24h", Refresh: "30s",
	}).WithPanel(availabilityStat(AvailabilityStatOptions{
		ID: stats[0].ID, Grid: stats[0].Grid, Title: "Vikunja Up",
		Expression: "max(" + serviceMetric("up") + ")", Legend: "Vikunja", DataSource: datasource,
	}))

	statDefinitions := []struct {
		title      string
		expression string
		legend     string
	}{
		{
			title: "Active Users (5m)",
			expression: "max(max_over_time(" + serviceMetric("vikunja_active_users") +
				"[5m])) or vector(0)",
			legend: "active users",
		},
		{title: "Users", expression: "max(" + serviceMetric("vikunja_user_count") + ") or vector(0)", legend: "users"},
		{
			title: "Projects",
			expression: "max((" + serviceMetric("vikunja_project_count") + ") or (" +
				serviceMetric("vikunja_list_count") + ")) or vector(0)",
			legend: "projects",
		},
	}
	for index, definition := range statDefinitions {
		placement := stats[index+1]
		builder.WithPanel(valueStat(ValueStatOptions{
			ID: placement.ID, Grid: placement.Grid, Title: definition.title,
			Expression: definition.expression, Legend: definition.legend,
			Unit: units.Short, DataSource: datasource,
		}))
	}

	resourcePanels := layout.row(8, 12, 12)
	builder.
		WithPanel(timeSeries(TimeseriesOptions{
			ID: resourcePanels[0].ID, Grid: resourcePanels[0].Grid, Title: "Resident Memory",
			Unit: units.BytesIEC, DataSource: datasource,
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: serviceMetric("process_resident_memory_bytes"), Legend: "{{instance}}",
			}},
		})).
		WithPanel(timeSeries(TimeseriesOptions{
			ID: resourcePanels[1].ID, Grid: resourcePanels[1].Grid, Title: "Go Goroutines",
			Unit: units.Short, DataSource: datasource,
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: serviceMetric("go_goroutines"), Legend: "{{instance}}",
			}},
		}))
	tasks := layout.row(8, 24)[0]
	builder.WithPanel(timeSeries(TimeseriesOptions{
		ID: tasks.ID, Grid: tasks.Grid, Title: "Tasks", Unit: units.Short, DataSource: datasource,
		Targets: []PrometheusTarget{{
			RefID: "A", Expression: "max(" + serviceMetric("vikunja_task_count") + ") or vector(0)", Legend: "tasks",
		}},
	}))

	return builder.Build()
}

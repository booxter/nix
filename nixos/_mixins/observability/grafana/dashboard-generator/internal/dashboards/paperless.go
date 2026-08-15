package dashboards

import (
	"fmt"

	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func PaperlessOverview(config Config) (dashboard.Dashboard, error) {
	paperlessHost, err := config.serviceHost("paperless")
	if err != nil {
		return dashboard.Dashboard{}, err
	}
	gptHost, err := config.serviceHost("paperless-gpt")
	if err != nil {
		return dashboard.Dashboard{}, err
	}

	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	paperless := func(name string, matchers ...string) string {
		return applicationMetric(name, "paperless", matchers...)
	}
	gptNode := func(name string, matchers ...string) string {
		return nodeMetric(name, append([]string{fmt.Sprintf("instance=%q", gptHost)}, matchers...)...)
	}

	builder := newDashboard(DashboardOptions{
		Title: "Paperless", UID: "paperless-stack", Tags: []string{"paperless", "documents"},
		From: "now-24h", Refresh: "30s",
	})
	summary := layout.row(4, 6, 6, 6, 6)
	builder.
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: summary[0].ID, Grid: summary[0].Grid, Title: "Paperless Scrape",
			Expression: "max(" + paperless("up") + ")", Legend: paperlessHost,
			DataSource: datasource,
		})).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: summary[1].ID, Grid: summary[1].Grid, Title: "Paperless Health",
			Expression: `min({__name__=~"paperless_status_(database|redis|celery|index|classifier|sanity_check)_status",scrape_profile="application",service="paperless"})`,
			Legend:     "components", DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[2].ID, Grid: summary[2].Grid, Title: "Documents",
			Expression: paperless("paperless_statistics_documents_total"), Legend: "documents",
			Unit: units.Short, DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[3].ID, Grid: summary[3].Grid, Title: "Paperless Storage Used",
			Expression: "100 * (1 - " + paperless("paperless_status_storage_available_bytes") +
				" / " + paperless("paperless_status_storage_total_bytes") + ")",
			Legend: "used", Unit: units.Percent, DataSource: datasource,
			Thresholds: warningCriticalThresholds(75, 90),
		}))

	components := layout.row(6, 24)[0]
	componentMetrics := []struct {
		name  string
		label string
	}{
		{name: "paperless_status_celery_status", label: "celery"},
		{name: "paperless_status_classifier_status", label: "classifier"},
		{name: "paperless_status_database_status", label: "database"},
		{name: "paperless_status_index_status", label: "index"},
		{name: "paperless_status_redis_status", label: "redis"},
		{name: "paperless_status_sanity_check_status", label: "sanity check"},
	}
	componentExpression := ""
	for index, component := range componentMetrics {
		if index != 0 {
			componentExpression += " or "
		}
		componentExpression += fmt.Sprintf(
			`label_replace(%s, "component", %q, "__name__", ".*")`,
			paperless(component.name), component.label,
		)
	}
	builder.WithPanel(stateTimeline(StateTimelineOptions{
		ID: components.ID, Grid: components.Grid, Title: "Paperless Component Health",
		Expression: componentExpression, Legend: "{{component}}", DataSource: datasource,
	}))

	series := layout.row(8, 12, 12)
	builder.
		WithPanel(timeSeries(TimeseriesOptions{
			ID: series[0].ID, Grid: series[0].Grid, Title: "Documents Over Time",
			Unit: units.Short, DataSource: datasource, Min: ptr(0.0),
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: paperless("paperless_statistics_documents_total"), Legend: "documents",
			}},
		})).
		WithPanel(timeSeries(TimeseriesOptions{
			ID: series[1].ID, Grid: series[1].Grid, Title: "Paperless Storage",
			Unit: units.BytesIEC, DataSource: datasource, Min: ptr(0.0),
			Targets: []PrometheusTarget{
				{RefID: "A", Expression: paperless("paperless_status_storage_total_bytes"), Legend: "total"},
				{RefID: "B", Expression: paperless("paperless_status_storage_available_bytes"), Legend: "available"},
			},
		}))

	tables := layout.row(8, 12, 12)
	builder.
		WithPanel(metricTable(MetricTableOptions{
			ID: tables[0].ID, Grid: tables[0].Grid, Title: "Documents By MIME Type",
			Expression: paperless("paperless_statistics_documents_file_type_counts"),
			Unit:       units.Short, DataSource: datasource,
		})).
		WithPanel(metricTable(MetricTableOptions{
			ID: tables[1].ID, Grid: tables[1].Grid, Title: "Inventory Counts",
			Expression: inventoryCountExpression(paperless), Unit: units.Short,
			DataSource: datasource,
		}))

	gpt := layout.row(4, 12, 12)
	builder.
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: gpt[0].ID, Grid: gpt[0].Grid, Title: "Paperless GPT Probe",
			Expression: `max(probe_success{probe_family="service",probe_role="frontdoor",service="paperless-gpt"})`,
			Legend:     "probe", DataSource: datasource,
		})).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: gpt[1].ID, Grid: gpt[1].Grid, Title: "Paperless GPT Units",
			Expression: "sum(" + gptNode("node_systemd_unit_state",
				`name=~"podman-paperless-gpt\\.service|oauth2-proxy-paperless-gpt\\.service"`, `state="active"`) + ") / 2",
			Legend: "units", DataSource: datasource,
		}))

	return builder.Build()
}

func inventoryCountExpression(metric func(string, ...string) string) string {
	counts := []struct {
		name  string
		label string
	}{
		{name: "paperless_statistics_tag_count", label: "tags"},
		{name: "paperless_statistics_correspondent_count", label: "correspondents"},
		{name: "paperless_statistics_document_type_count", label: "document types"},
		{name: "paperless_statistics_storage_path_count", label: "storage paths"},
	}
	expression := ""
	for index, count := range counts {
		if index != 0 {
			expression += " or "
		}
		expression += fmt.Sprintf(
			`label_replace(%s, "item", %q, "__name__", ".*")`,
			metric(count.name), count.label,
		)
	}
	return expression
}

package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func SSOOverview(config Config) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	unitsPanel := layout.row(7, 24)[0]
	probesPanel := layout.row(7, 24)[0]

	unitExpression := `node_systemd_unit_state{scrape_profile="node",state="active"} * on(instance,name) group_left(service,sso_gate,sso_role) nixos_systemd_unit_expected_active{sso_role=~"provider|client|gate"}`

	return newDashboard(DashboardOptions{
		Title: "OIDC / SSO", UID: "oidc-sso", Tags: []string{"oidc", "sso"},
		From: "now-6h", Refresh: "30s",
	}).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: unitsPanel.ID, Grid: unitsPanel.Grid, Title: "OIDC service units",
			Expression: unitExpression, Legend: "{{instance}} / {{name}}", DataSource: datasource,
		})).
		WithPanel(timeSeries(TimeseriesOptions{
			ID: probesPanel.ID, Grid: probesPanel.Grid, Title: "HTTP login surface probes",
			Unit: units.Short, DataSource: datasource, Min: ptr(0.0), Max: ptr(1.0),
			Mappings:   []dashboard.ValueMapping{availabilityMapping()},
			Thresholds: redToGreenThreshold(1),
			Targets: []PrometheusTarget{{
				RefID:      "A",
				Expression: `probe_success{probe_family="service",probe_role="frontdoor",sso_role=~"provider|client"}`,
				Legend:     "{{service_title}} / {{source}}",
			}},
		})).
		Build()
}

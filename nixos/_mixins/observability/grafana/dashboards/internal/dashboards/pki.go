package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func PKIOverview(config Config) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	placements := layout.row(8, 24)
	placements = append(placements, layout.row(8, 24)...)
	certificateThresholds := absoluteThresholds(
		dashboard.Threshold{Color: "red", Value: nil},
		dashboard.Threshold{Color: "orange", Value: ptr(7.0)},
		dashboard.Threshold{Color: "green", Value: ptr(30.0)},
	)

	return newDashboard(DashboardOptions{
		Title: "PKI / TLS", UID: "pki-overview", Tags: []string{"pki", "tls"},
		From: "now-24h", Refresh: "1m",
	}).
		WithPanel(valueStat(ValueStatOptions{
			ID: placements[0].ID, Grid: placements[0].Grid,
			Title: "Private TLS Certificate Days Remaining", Unit: units.Days,
			Expression: `min by (host) ((((host_observability_pki_cert_parse_success{scrape_profile="node"} == bool 0) * -1) != 0) or on(host,category,cert_name) host_observability_pki_cert_days_remaining{scrape_profile="node"})`,
			Legend:     "{{host}}", DataSource: datasource, Background: true,
			Mappings: []dashboard.ValueMapping{exactValueMapping(map[string]dashboard.ValueMappingResult{
				"-1": mappedValue("Missing", "red", 0),
			})},
			Thresholds: certificateThresholds,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: placements[1].ID, Grid: placements[1].Grid,
			Title: "Public TLS Certificate Days Remaining", Unit: units.Days,
			Expression: `(probe_ssl_earliest_cert_expiry{probe_family="service",probe_role="frontdoor",scope="external"} - time()) / 86400`,
			Legend:     "{{service_title}}", DataSource: datasource, Background: true,
			Thresholds: certificateThresholds,
		})).
		Build()
}

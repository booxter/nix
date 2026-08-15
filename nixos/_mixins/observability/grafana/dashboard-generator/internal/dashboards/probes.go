package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

type ProbeSeries struct {
	Title      string
	Expression string
	Legend     string
	Unit       string
	Thresholds *dashboard.ThresholdsConfigBuilder
}

type ProbeOverviewOptions struct {
	Title          string
	UID            string
	Tags           []string
	Availabilities []ProbeAvailability
	Series         []ProbeSeries
}

type ProbeAvailability struct {
	Title      string
	Expression string
	Legend     string
}

func ProbeOverview(config Config, options ProbeOverviewOptions) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()

	builder := newDashboard(DashboardOptions{
		Title: options.Title, UID: options.UID, Tags: options.Tags,
		From: "now-6h", Refresh: "30s",
	})
	for _, availability := range options.Availabilities {
		placement := layout.row(8, 24)[0]
		builder.WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: placement.ID, Grid: placement.Grid,
			Title: availability.Title, Expression: availability.Expression,
			Legend: availability.Legend, DataSource: datasource,
		}))
	}

	for offset := 0; offset < len(options.Series); {
		remaining := len(options.Series) - offset
		rowLength := min(2, remaining)
		widths := []uint32{24}
		if rowLength == 2 {
			widths = []uint32{12, 12}
		}
		placements := layout.row(8, widths...)
		for index := range rowLength {
			series := options.Series[offset+index]
			placement := placements[index]
			builder.WithPanel(timeSeries(TimeseriesOptions{
				ID: placement.ID, Title: series.Title, Unit: series.Unit,
				Grid: placement.Grid, DataSource: datasource, Thresholds: series.Thresholds,
				Targets: []PrometheusTarget{{
					RefID: "A", Expression: series.Expression, Legend: series.Legend,
				}},
			}))
		}
		offset += rowLength
	}

	return builder.Build()
}

func ServiceProbeOverview(config Config) (dashboard.Dashboard, error) {
	return ProbeOverview(config, ProbeOverviewOptions{
		Title: "Services", UID: "arr-services", Tags: []string{"services", "blackbox"},
		Availabilities: []ProbeAvailability{{
			Title: "Current availability", Expression: `probe_success{probe_family="service",probe_role="frontdoor"}`,
			Legend: "{{service_title}}",
		}},
		Series: []ProbeSeries{
			{
				Title: "Probe duration", Unit: units.Seconds,
				Expression: `avg_over_time(probe_duration_seconds{probe_family="service",probe_role="frontdoor"}[5m])`,
				Legend:     "{{service_title}}",
			},
			{
				Title: "HTTP status code", Unit: units.Short,
				Expression: `probe_http_status_code{probe_family="service",probe_role="frontdoor"}`,
				Legend:     "{{service_title}}",
				Thresholds: absoluteThresholds(
					dashboard.Threshold{Color: "green", Value: nil},
					dashboard.Threshold{Color: "orange", Value: ptr(300.0)},
					dashboard.Threshold{Color: "red", Value: ptr(400.0)},
				),
			},
		},
	})
}

func ResolverProbeOverview(config Config) (dashboard.Dashboard, error) {
	return ProbeOverview(config, ProbeOverviewOptions{
		Title: "Resolver Health", UID: "fana-dhcp-dns-overview", Tags: []string{"dns", "network"},
		Availabilities: []ProbeAvailability{
			{
				Title: "Current resolver availability", Expression: `probe_success{probe_family="dns",probe_role="resolver"}`,
				Legend: "{{resolver_title}}",
			},
			{
				Title: "Gateway DNS TCP reachability", Expression: `probe_success{probe_family="network",probe="gateway-dns"}`,
				Legend: "{{probe_title}}",
			},
		},
		Series: []ProbeSeries{
			{
				Title: "DNS probe duration", Unit: units.Seconds,
				Expression: `avg_over_time(probe_duration_seconds{probe_family="dns",probe_role="resolver"}[5m])`,
				Legend:     "{{resolver_title}}",
			},
			{
				Title: "Gateway DNS TCP connect duration", Unit: units.Seconds,
				Expression: `avg_over_time(probe_duration_seconds{probe_family="network",probe="gateway-dns"}[5m])`,
				Legend:     "{{probe_title}}",
			},
		},
	})
}

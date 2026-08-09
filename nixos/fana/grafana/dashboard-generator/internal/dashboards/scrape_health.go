package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/common"
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/timeseries"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func ScrapeHealth(config Config) (dashboard.Dashboard, error) {
	serviceScrapes := `up{scrape_profile="application"}`
	blackboxScrapes := `min by(probe_family, source) (up{scrape_profile="probe"})`
	prometheusDatasource := config.DataSources.Prometheus.reference()

	return newDashboard(DashboardOptions{
		Title:   "Scrape Health",
		UID:     "scrape-health",
		Tags:    []string{"observability", "scrapes"},
		From:    "now-6h",
		Refresh: "30s",
	}).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: 1, Grid: grid(0, 0, 24, 8), Title: "Current mTLS Service Scrapes",
			Expression: serviceScrapes, Legend: "{{service}} / {{component}}", DataSource: prometheusDatasource,
		})).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: 2, Grid: grid(0, 8, 24, 8), Title: "Current Blackbox Scrape Transport",
			Expression: blackboxScrapes, Legend: "{{probe_family}} / {{source}}", DataSource: prometheusDatasource,
		})).
		WithPanel(timeseries.NewPanelBuilder().
			Id(3).
			Title("Scrape Availability Over Time").
			Datasource(prometheusDatasource).
			GridPos(grid(0, 16, 24, 8)).
			Unit(units.Short).
			Thresholds(redToGreenThreshold(1)).
			Legend(common.NewVizLegendOptionsBuilder().
				DisplayMode(common.LegendDisplayModeList).
				Placement(common.LegendPlacementBottom).
				ShowLegend(true)).
			Tooltip(common.NewVizTooltipOptionsBuilder().
				Mode(common.TooltipDisplayModeMulti).
				Sort(common.SortOrderDescending)).
			WithTarget(prometheusQuery("A", serviceScrapes, "{{service}} / {{component}}", false)).
			WithTarget(prometheusQuery("B", blackboxScrapes, "{{probe_family}} / {{source}}", false))).
		Build()
}

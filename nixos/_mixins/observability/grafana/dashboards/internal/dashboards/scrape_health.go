package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/common"
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/timeseries"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func ScrapeHealth(config Config) (dashboard.Dashboard, error) {
	serviceScrapes := `up{job=~"smartctl|jellyfin|lolek|paperless|sabnzbd|vikunja"}`
	blackboxScrapes := `min by(job, source) (up{job=~"blackbox-icmp|blackbox-tcp"})`
	prometheusDatasource := config.DataSources.Prometheus.reference()

	return newDashboard(DashboardOptions{
		Title:   "Scrape Health",
		UID:     "scrape-health",
		Tags:    []string{"observability", "scrapes"},
		From:    "now-6h",
		Refresh: "30s",
	}).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: 1, Y: 0, Title: "Current mTLS Service Scrapes",
			Expression: serviceScrapes, Legend: "{{job}}", DataSource: prometheusDatasource,
		})).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: 2, Y: 8, Title: "Current Blackbox Scrape Transport",
			Expression: blackboxScrapes, Legend: "{{job}} / {{source}}", DataSource: prometheusDatasource,
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
			WithTarget(prometheusQuery("A", serviceScrapes, "{{job}}", false)).
			WithTarget(prometheusQuery("B", blackboxScrapes, "{{job}} / {{source}}", false))).
		Build()
}

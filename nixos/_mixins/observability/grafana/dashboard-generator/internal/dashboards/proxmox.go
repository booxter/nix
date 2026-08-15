package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func ProxmoxOverview(config Config) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	metric := func(name string, matchers ...string) string {
		return profileMetric(name, "hypervisor", append([]string{`component="proxmox"`}, matchers...)...)
	}
	summary := layout.row(5, 6, 6, 6, 6)
	builder := newDashboard(DashboardOptions{
		Title: "Proxmox", UID: "proxmox-lab", Tags: []string{"proxmox", "virtualization"},
		From: "now-6h", Refresh: "30s",
	}).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: summary[0].ID, Grid: summary[0].Grid, Title: "Cluster Up",
			Expression: "min(" + metric("pve_up", `id=~"cluster/.*"`) + ")", Legend: "cluster", DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[1].ID, Grid: summary[1].Grid, Title: "Nodes Online",
			Expression: "sum(" + metric("pve_up", `id=~"node/.*"`) + ")",
			Legend:     "nodes", Unit: units.Short, DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[2].ID, Grid: summary[2].Grid, Title: "Guests Running",
			Expression: "sum(" + metric("pve_up", `id=~"(qemu|lxc)/.*"`) + ")",
			Legend:     "guests", Unit: units.Short, DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[3].ID, Grid: summary[3].Grid, Title: "Failed Scrapes",
			Expression: "sum(" + metric("up") + " == 0) or vector(0)",
			Legend:     "failed", Unit: units.Short, DataSource: datasource,
			Thresholds: greenToRedThreshold(1),
		}))

	series := []struct {
		title      string
		expression string
		legend     string
	}{
		{
			title: "Node CPU", legend: "{{id}}",
			expression: metric("pve_cpu_usage_ratio", `id=~"node/.*"`) + " * 100",
		},
		{
			title: "Node Memory", legend: "{{id}}",
			expression: metric("pve_memory_usage_bytes", `id=~"node/.*"`) + " / " +
				metric("pve_memory_size_bytes", `id=~"node/.*"`) + " * 100",
		},
		{
			title: "Storage Usage", legend: "{{id}}",
			expression: metric("pve_disk_usage_bytes", `id=~"storage/.*"`) + " / " +
				metric("pve_disk_size_bytes", `id=~"storage/.*"`) + " * 100",
		},
		{
			title: "Top Guest CPU", legend: "{{name}} / {{node}}",
			expression: "topk(10, " + metric("pve_cpu_usage_ratio", `id=~"(qemu|lxc)/.*"`) +
				" * on(id) group_left(name,node,type,tags) " + metric("pve_guest_info") + " * 100)",
		},
	}
	for offset := 0; offset < len(series); offset += 2 {
		placements := layout.row(8, 12, 12)
		for index, placement := range placements {
			definition := series[offset+index]
			builder.WithPanel(timeSeries(TimeseriesOptions{
				ID: placement.ID, Grid: placement.Grid, Title: definition.title,
				Unit: units.Percent, DataSource: datasource, Min: ptr(0.0), Max: ptr(100.0),
				Targets: []PrometheusTarget{{
					RefID: "A", Expression: definition.expression, Legend: definition.legend,
				}},
			}))
		}
	}
	guestTable := layout.row(8, 24)[0]
	builder.WithPanel(metricTable(MetricTableOptions{
		ID: guestTable.ID, Grid: guestTable.Grid, Title: "Guest State", Unit: units.Short,
		Expression: metric("pve_up", `id=~"(qemu|lxc)/.*"`) +
			" * on(id) group_left(name,node,type,tags) " + metric("pve_guest_info"),
		DataSource: datasource,
	}))

	return builder.Build()
}

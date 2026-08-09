package dashboards

import (
	"fmt"

	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

type networkSeries struct {
	title          string
	expression     string
	legend         string
	unit           string
	thresholds     *dashboard.ThresholdsConfigBuilder
	stacking       string
	softMax        *float64
	showThresholds bool
}

func NetworkOverview(config Config) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	classified := func(direction, scope string) string {
		return nodeMetric("host_observability_network_bytes_total",
			`host_network_source="classified"`, fmt.Sprintf(`direction=%q`, direction), fmt.Sprintf(`scope=%q`, scope))
	}
	nodeInterface := func(metric string) string {
		return nodeMetric(metric, `host_network_source="node"`, fmt.Sprintf(`device!~%q`, physicalInterfaceExclusion))
	}
	hostBandwidth := func(nodeCounter, direction string) string {
		return `(sum by(instance) (rate(` + nodeInterface(nodeCounter) + `[5m])) or sum by(instance) (rate(` +
			nodeMetric("host_observability_network_bytes_total", `host_network_source="classified"`,
				fmt.Sprintf(`direction=%q`, direction)) + `[5m]))) * 8`
	}
	bits := func(megabits float64) float64 { return megabits * 1_000_000 }
	internet := config.Network.Internet

	series := []networkSeries{
		{
			title: "WAN Inbound Bandwidth", unit: units.BitsPerSecondSI, legend: "{{instance}}",
			expression: `sum by(instance) (rate(` + classified("receive", "wan") + `[5m])) * 8`,
			thresholds: warningCriticalThresholds(bits(internet.Ingress.TargetMbit), bits(internet.Ingress.CapacityMbit)),
			stacking:   "wan-in", softMax: ptr(bits(internet.Ingress.CapacityMbit)), showThresholds: true,
		},
		{
			title: "WAN Outbound Bandwidth", unit: units.BitsPerSecondSI, legend: "{{instance}}",
			expression: `sum by(instance) (rate(` + classified("transmit", "wan") + `[5m])) * 8`,
			thresholds: warningCriticalThresholds(bits(internet.Egress.TargetMbit), bits(internet.Egress.CapacityMbit)),
			stacking:   "wan-out", softMax: ptr(bits(internet.Egress.CapacityMbit)), showThresholds: true,
		},
		{
			title: "LAN Inbound Bandwidth", unit: units.BitsPerSecondSI, legend: "{{instance}}",
			expression: `sum by(instance) (rate(` + classified("receive", "lan") + `[5m])) * 8`, stacking: "lan-in",
		},
		{
			title: "LAN Outbound Bandwidth", unit: units.BitsPerSecondSI, legend: "{{instance}}",
			expression: `sum by(instance) (rate(` + classified("transmit", "lan") + `[5m])) * 8`, stacking: "lan-out",
		},
		{
			title: "Inbound Bandwidth By Host", unit: units.BitsPerSecondSI, legend: "{{instance}}",
			expression: hostBandwidth("node_network_receive_bytes_total", "receive"), stacking: "host-in",
		},
		{
			title: "Outbound Bandwidth By Host", unit: units.BitsPerSecondSI, legend: "{{instance}}",
			expression: hostBandwidth("node_network_transmit_bytes_total", "transmit"), stacking: "host-out",
		},
		{
			title: "Errors And Drops", unit: units.PacketsPerSecond, legend: "{{instance}}",
			expression: `sum by(instance) (rate(` + nodeInterface("node_network_receive_errs_total") + `[5m]) + rate(` +
				nodeInterface("node_network_transmit_errs_total") + `[5m]) + rate(` +
				nodeInterface("node_network_receive_drop_total") + `[5m]) + rate(` +
				nodeInterface("node_network_transmit_drop_total") + `[5m])) or on(instance) ` +
				nodeMetric("up", `host_network_source="classified"`) + ` * 0`,
		},
		{
			title: "TCP Retransmits", unit: units.Short, legend: "{{instance}}",
			expression: `sum by(instance) (rate(` + nodeMetric("node_netstat_Tcp_RetransSegs") +
				`[5m])) and on(instance) max by(instance) (` + classified("receive", "wan") + `)`,
		},
		{
			title: "Ping RTT", unit: units.Milliseconds, legend: "{{probe_title}} / {{source}}",
			expression: `probe_duration_seconds{probe_family="network",probe_protocol="icmp"} * 1000`,
		},
		{
			title: "TCP Connect Latency", unit: units.Milliseconds, legend: "{{probe_title}} / {{source}}",
			expression: `probe_duration_seconds{probe_family="network",probe_protocol="tcp"} * 1000`,
		},
		{
			title: "Ping Loss (5m)", unit: units.Percent, legend: "{{probe_title}} / {{source}}",
			expression: `100 * (1 - avg_over_time(probe_success{probe_family="network",probe_protocol="icmp"}[5m]))`,
		},
		{
			title: "TCP Connect Loss (5m)", unit: units.Percent, legend: "{{probe_title}} / {{source}}",
			expression: `100 * (1 - avg_over_time(probe_success{probe_family="network",probe_protocol="tcp"}[5m]))`,
		},
	}

	builder := newDashboard(DashboardOptions{
		Title: "Network", UID: "fana-network-overview", Tags: []string{"network", "fleet"},
		From: "now-6h", Refresh: "30s",
	})
	placements := make([]panelPlacement, 0, len(series))
	for range len(series) / 2 {
		placements = append(placements, layout.row(8, 12, 12)...)
	}
	fill := 20.0
	for index, definition := range series {
		placement := placements[index]
		var fillOpacity *float64
		if definition.stacking != "" {
			fillOpacity = &fill
		}
		builder.WithPanel(timeSeries(TimeseriesOptions{
			ID: placement.ID, Grid: placement.Grid, Title: definition.title,
			Unit: definition.unit, DataSource: datasource, Min: ptr(0.0), SoftMax: definition.softMax,
			Thresholds: definition.thresholds, Stacking: definition.stacking,
			Fill: fillOpacity, ShowThresholds: definition.showThresholds,
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: definition.expression, Legend: definition.legend,
			}},
		}))
	}

	return builder.Build()
}

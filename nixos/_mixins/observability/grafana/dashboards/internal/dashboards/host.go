package dashboards

import (
	"fmt"
	"slices"

	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func hostTags(host Host) []string {
	tags := []string{"host", host.Platform, host.CapacityProfile}
	if host.Virtual {
		tags = append(tags, "virtual")
	} else {
		tags = append(tags, "hardware")
	}
	if host.Builder {
		tags = append(tags, "builder")
	}
	if host.Hypervisor {
		tags = append(tags, "hypervisor")
	}
	if host.Storage.DiskBays {
		tags = append(tags, "storage")
	}
	if host.Backups.Server {
		tags = append(tags, "backup-server")
	}
	if host.GPUVendor != nil {
		tags = append(tags, "gpu-"+*host.GPUVendor)
	}
	slices.Sort(tags)
	return slices.Compact(tags)
}

func hostNetworkTargets(host Host, selector string) []PrometheusTarget {
	if host.Hypervisor {
		return []PrometheusTarget{
			{
				RefID: "A", Legend: "receive",
				Expression: fmt.Sprintf(`sum(rate(host_observability_network_bytes_total{%s,host_network_source="classified",direction="receive"}[$__rate_interval])) * 8`, selector),
			},
			{
				RefID: "B", Legend: "transmit",
				Expression: fmt.Sprintf(`sum(rate(host_observability_network_bytes_total{%s,host_network_source="classified",direction="transmit"}[$__rate_interval])) * 8`, selector),
			},
		}
	}

	deviceExclusion := `lo|usb.*|veth.*|docker.*|br-.*|virbr.*|vnet.*|zt.*|tailscale.*|wg.*|tun.*`
	return []PrometheusTarget{
		{
			RefID: "A", Legend: "receive",
			Expression: fmt.Sprintf(`sum(rate(node_network_receive_bytes_total{%s,host_network_source="node",device!~"%s"}[$__rate_interval])) * 8`, selector, deviceExclusion),
		},
		{
			RefID: "B", Legend: "transmit",
			Expression: fmt.Sprintf(`sum(rate(node_network_transmit_bytes_total{%s,host_network_source="node",device!~"%s"}[$__rate_interval])) * 8`, selector, deviceExclusion),
		},
	}
}

func HostDashboard(config Config, host Host) (dashboard.Dashboard, error) {
	datasource := config.DataSources.Prometheus.reference()
	selector := fmt.Sprintf(`scrape_profile="node",instance="%s"`, host.Name)
	layout := newPanelLayout()

	summaryWidths := []uint32{12, 12}
	if host.Platform == "linux" {
		summaryWidths = []uint32{8, 8, 8}
	}
	summary := layout.row(6, summaryWidths...)

	builder := newDashboard(DashboardOptions{
		Title:   "Host: " + host.Name,
		UID:     "host-" + host.Name,
		Tags:    hostTags(host),
		From:    "now-6h",
		Refresh: "30s",
	}).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: summary[0].ID, Grid: summary[0].Grid, Title: "Node Exporter",
			Expression: fmt.Sprintf("max(up{%s})", selector), Legend: host.Name,
			DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[1].ID, Title: "Uptime",
			Expression: fmt.Sprintf("time() - node_boot_time_seconds{%s}", selector),
			Legend:     host.Name, Unit: units.DurationInDaysHoursMinutesSeconds,
			Grid: summary[1].Grid, DataSource: datasource,
		}))

	if host.Platform == "linux" {
		builder.WithPanel(valueStat(ValueStatOptions{
			ID: summary[2].ID, Title: "Failed systemd units",
			Expression: fmt.Sprintf(`sum(node_systemd_unit_state{%s,state="failed"}) or vector(0)`, selector),
			Legend:     "failed", Unit: units.Short, Grid: summary[2].Grid,
			DataSource: datasource, Thresholds: greenToRedThreshold(1),
		}))
	}

	resources := layout.row(8, 12, 12)
	builder.
		WithPanel(timeSeries(TimeseriesOptions{
			ID: resources[0].ID, Title: "CPU busy", Unit: units.Percent,
			Grid: resources[0].Grid, DataSource: datasource, Min: ptr(0.0), Max: ptr(100.0),
			Targets: []PrometheusTarget{{
				RefID: "A", Legend: host.Name,
				Expression: fmt.Sprintf(`100 - (avg(rate(node_cpu_seconds_total{%s,mode="idle"}[$__rate_interval])) * 100)`, selector),
			}},
		})).
		WithPanel(timeSeries(TimeseriesOptions{
			ID: resources[1].ID, Title: "Memory used", Unit: units.Percent,
			Grid: resources[1].Grid, DataSource: datasource, Min: ptr(0.0), Max: ptr(100.0),
			Targets: []PrometheusTarget{{
				RefID: "A", Legend: host.Name,
				Expression: fmt.Sprintf(`100 * ((1 - (node_memory_MemAvailable_bytes{%[1]s} / node_memory_MemTotal_bytes{%[1]s})) or (1 - ((node_memory_free_bytes{%[1]s} + node_memory_inactive_bytes{%[1]s}) / node_memory_total_bytes{%[1]s})))`, selector),
			}},
		}))

	filesystem := layout.row(8, 24)[0]
	builder.WithPanel(timeSeries(TimeseriesOptions{
		ID: filesystem.ID, Title: "Root filesystem used", Unit: units.Percent,
		Grid: filesystem.Grid, DataSource: datasource, Min: ptr(0.0), Max: ptr(100.0),
		Targets: []PrometheusTarget{{
			RefID: "A", Legend: host.Name,
			Expression: fmt.Sprintf(`100 * (1 - (node_filesystem_avail_bytes{%[1]s,mountpoint="/",fstype!=""} / node_filesystem_size_bytes{%[1]s,mountpoint="/",fstype!=""}))`, selector),
		}},
	}))

	network := layout.row(8, 24)[0]
	builder.WithPanel(timeSeries(TimeseriesOptions{
		ID: network.ID, Title: "Network throughput", Unit: units.BitsPerSecondSI,
		Grid: network.Grid, DataSource: datasource, Min: ptr(0.0),
		Targets: hostNetworkTargets(host, selector),
	}))

	if host.ThermalProfile != "none" {
		thermal := layout.row(8, 24)[0]
		builder.WithPanel(timeSeries(TimeseriesOptions{
			ID: thermal.ID, Title: "Temperature", Unit: units.Celsius,
			Grid: thermal.Grid, DataSource: datasource,
			Targets: []PrometheusTarget{{
				RefID: "A", Legend: "{{sensor}} {{type}} {{group}}",
				Expression: fmt.Sprintf(`node_thermal_zone_temp{%[1]s} or node_hwmon_temp_celsius{%[1]s} or host_observability_darwin_temperature_group_max_celsius{%[1]s}`, selector),
			}},
		}))
	}

	if host.Hypervisor {
		hypervisor := layout.row(8, 12, 12)
		builder.
			WithPanel(timeSeries(TimeseriesOptions{
				ID: hypervisor[0].ID, Title: "Proxmox CPU used", Unit: units.Percent,
				Grid: hypervisor[0].Grid, DataSource: datasource, Min: ptr(0.0), Max: ptr(100.0),
				Targets: []PrometheusTarget{{
					RefID: "A", Legend: host.Name,
					Expression: fmt.Sprintf(`pve_cpu_usage_ratio{component="proxmox",id="node/%s"} * 100`, host.Name),
				}},
			})).
			WithPanel(timeSeries(TimeseriesOptions{
				ID: hypervisor[1].ID, Title: "Proxmox memory used", Unit: units.Percent,
				Grid: hypervisor[1].Grid, DataSource: datasource, Min: ptr(0.0), Max: ptr(100.0),
				Targets: []PrometheusTarget{{
					RefID: "A", Legend: host.Name,
					Expression: fmt.Sprintf(`pve_memory_usage_bytes{component="proxmox",id="node/%[1]s"} / pve_memory_size_bytes{component="proxmox",id="node/%[1]s"} * 100`, host.Name),
				}},
			}))
	}

	if host.Storage.DiskBays {
		storage := layout.row(8, 24)[0]
		builder.WithPanel(timeSeries(TimeseriesOptions{
			ID: storage.ID, Title: "Disk temperatures", Unit: units.Celsius,
			Grid: storage.Grid, DataSource: datasource,
			Targets: []PrometheusTarget{{
				RefID: "A", Legend: "{{device}}",
				Expression: fmt.Sprintf(`smartctl_device_temperature{instance="%s",temperature_type="current"}`, host.Name),
			}},
		}))
	}

	return builder.Build()
}

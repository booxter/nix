package dashboards

import (
	"fmt"

	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func MediaOverview(config Config) (dashboard.Dashboard, error) {
	mediaHost, err := config.serviceHost("transmission")
	if err != nil {
		return dashboard.Dashboard{}, err
	}
	for _, service := range []string{"lidarr", "sabnzbd"} {
		host, hostErr := config.serviceHost(service)
		if hostErr != nil {
			return dashboard.Dashboard{}, hostErr
		}
		if host != mediaHost {
			return dashboard.Dashboard{}, fmt.Errorf("media service %q is on %q, want %q", service, host, mediaHost)
		}
	}

	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	node := func(metric string, matchers ...string) string {
		return nodeMetric(metric, append([]string{fmt.Sprintf(`instance=%q`, mediaHost)}, matchers...)...)
	}
	jellyfin := func(metric string, matchers ...string) string {
		return applicationMetric(metric, "jellyfin", matchers...)
	}
	sabnzbd := func(metric string, matchers ...string) string {
		return applicationMetric(metric, "sabnzbd", matchers...)
	}

	builder := newDashboard(DashboardOptions{
		Title: "Media Pipeline", UID: "fana-media-pipe", Tags: []string{"media", "pipeline"},
		From: "now-24h", Refresh: "30s",
	})
	summary := layout.row(5, 4, 4, 4, 4, 4, 4)
	videoTypes := `type=~"Movie|Episode|Video|MusicVideo|Trailer"`
	remoteAddress := `ip_address!~"^(10\\..*|192\\.168\\..*|172\\.(1[6-9]|2[0-9]|3[01])\\..*|127\\..*|169\\.254\\..*|\\[?::1(?:\\])?$|\\[?fe80:.*|\\[?fc.*|\\[?fd.*)$"`
	statDefinitions := []struct {
		title      string
		expression string
		unit       string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{
			title: "VPN Enforced Cap",
			unit:  units.MegabitsPerSecond,
			expression: "sum(" + node("host_observability_adaptive_upload_target_mbit") +
				") or vector(0)",
		},
		{
			title: "VPN Target Cap",
			unit:  units.MegabitsPerSecond,
			expression: "sum(" + node("host_observability_adaptive_upload_observed_target_mbit") +
				") or vector(0)",
		},
		{
			title: "VPN Reserved Bitrate",
			unit:  units.MegabitsPerSecond,
			expression: "sum(" + node("host_observability_adaptive_upload_reserved_external_media_bandwidth_mbit") +
				") or vector(0)",
		},
		{
			title: "Jellyfin Active Video Streams",
			unit:  units.Short,
			expression: "sum(" + jellyfin("jellyfin_now_playing_state", videoTypes) +
				") or vector(0)",
			thresholds: warningCriticalThresholds(1, 2),
		},
		{
			title: "Jellyfin Remote Video Streams",
			unit:  units.Short,
			expression: "sum(" + jellyfin("jellyfin_now_playing_state", videoTypes) +
				" * on(user_id, username, device) group_left(ip_address) " +
				jellyfin("jellyfin_user_active", remoteAddress) + ") or vector(0)",
			thresholds: warningCriticalThresholds(1, 2),
		},
		{
			title: "Jellyfin Active Transcodes",
			unit:  units.Short,
			expression: "sum(" + jellyfin("jellyfin_now_playing_state", `method="transcode"`, videoTypes) +
				") or vector(0)",
			thresholds: warningCriticalThresholds(1, 2),
		},
	}
	for index, definition := range statDefinitions {
		placement := summary[index]
		builder.WithPanel(valueStat(ValueStatOptions{
			ID: placement.ID, Grid: placement.Grid, Title: definition.title,
			Expression: definition.expression, Legend: "", Unit: definition.unit,
			DataSource: datasource, Thresholds: definition.thresholds,
		}))
	}

	wan := layout.row(8, 24)[0]
	fill := 20.0
	egress := config.Network.Internet.Egress
	builder.WithPanel(timeSeries(TimeseriesOptions{
		ID: wan.ID, Grid: wan.Grid, Title: "WAN Outbound Bandwidth",
		Unit: units.BitsPerSecondSI, DataSource: datasource, Min: ptr(0.0),
		SoftMax: ptr(egress.CapacityMbit * 1_000_000), Stacking: "media-wan", Fill: &fill,
		ShowThresholds: true,
		Thresholds:     warningCriticalThresholds(30_000_000, egress.CapacityMbit*1_000_000),
		Targets: []PrometheusTarget{{
			RefID: "A", Legend: "{{instance}}",
			Expression: `sum by(instance) (rate(` + nodeMetric("host_observability_network_bytes_total",
				`direction="transmit"`, `scope="wan"`) + `[5m])) * 8`,
		}},
	}))

	transmissionSeries := []struct {
		title      string
		expression string
		legend     string
		unit       string
	}{
		{
			title: "Transmission Upload Throughput By Torrent Priority", unit: units.MegabitsPerSecond,
			expression: "avg_over_time(" + node("host_observability_transmission_upload_bytes_per_second", `class=~"high|normal|low"`) +
				"[5m]) * 8 / 1000000", legend: "{{class}}",
		},
		{
			title: "Transmission Download Throughput By Torrent Priority", unit: units.MegabitsPerSecond,
			expression: "avg_over_time(" + node("host_observability_transmission_download_bytes_per_second", `class=~"high|normal|low"`) +
				"[5m]) * 8 / 1000000", legend: "{{class}}",
		},
		{
			title: "Transmission Upload Peers By Torrent Priority", unit: units.Short,
			expression: node("host_observability_transmission_peer_count", `class=~"high|normal|low"`, `state="getting_from_us"`),
			legend:     "{{class}}",
		},
		{
			title: "Transmission Download Peers By Torrent Priority", unit: units.Short,
			expression: node("host_observability_transmission_peer_count", `class=~"high|normal|low"`, `state="sending_to_us"`),
			legend:     "{{class}}",
		},
		{
			title: "Transmission Seeding Torrents", unit: units.Short,
			expression: node("host_observability_transmission_torrent_activity_count", `direction="seeding"`),
			legend:     "{{activity}}",
		},
		{
			title: "Transmission Downloading Torrents", unit: units.Short,
			expression: node("host_observability_transmission_torrent_activity_count", `direction="downloading"`),
			legend:     "{{activity}}",
		},
	}
	for offset := 0; offset < len(transmissionSeries); offset += 2 {
		placements := layout.row(8, 12, 12)
		for index, placement := range placements {
			definition := transmissionSeries[offset+index]
			builder.WithPanel(timeSeries(TimeseriesOptions{
				ID: placement.ID, Grid: placement.Grid, Title: definition.title,
				Unit: definition.unit, DataSource: datasource, Min: ptr(0.0),
				Stacking: "transmission", Fill: &fill,
				Targets: []PrometheusTarget{{
					RefID: "A", Expression: definition.expression, Legend: definition.legend,
				}},
			}))
		}
	}

	sab := layout.row(8, 12, 12)
	builder.
		WithPanel(timeSeries(TimeseriesOptions{
			ID: sab[0].ID, Grid: sab[0].Grid, Title: "SABnzbd Queue Remaining",
			Unit: units.BytesIEC, DataSource: datasource, Min: ptr(0.0),
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: sabnzbd("sabnzbd_queue_remaining_bytes"), Legend: "queue remaining",
			}},
		})).
		WithPanel(timeSeries(TimeseriesOptions{
			ID: sab[1].ID, Grid: sab[1].Grid, Title: "SABnzbd Download Rate",
			Unit: units.BytesPerSecondSI, DataSource: datasource, Min: ptr(0.0),
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: sabnzbd("sabnzbd_queue_download_rate_bytes_per_second"), Legend: "download rate",
			}},
		}))

	cueSummary := layout.row(5, 6, 6, 6, 6)
	builder.WithPanel(availabilityStat(AvailabilityStatOptions{
		ID: cueSummary[0].ID, Grid: cueSummary[0].Grid, Title: "Lidarr Post-Processor Health",
		Expression: "max(" + node("host_observability_lidarr_post_processor_ok") + ") or vector(0)",
		Legend:     "health", DataSource: datasource,
	}))
	cueStats := []struct {
		title      string
		expression string
		unit       string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{
			title: "Repair Jobs In Flight", unit: units.Short,
			expression: "sum(" + node("host_observability_lidarr_post_processor_jobs",
				`state=~"settling|agent_starting|agent_running|agent_stopping|ready|staged|importing|awaiting_queue_removal"`) + ") or vector(0)",
			thresholds: absoluteThresholds(
				dashboard.Threshold{Color: "green", Value: nil},
				dashboard.Threshold{Color: "blue", Value: ptr(1.0)},
			),
		},
		{
			title: "Repair Jobs Needing Attention", unit: units.Short,
			expression: "sum(" + node("host_observability_lidarr_post_processor_jobs", `state="needs_attention"`) +
				") or vector(0)", thresholds: greenToRedThreshold(1),
		},
		{
			title: "Time Since Last Repair", unit: units.DurationInDaysHoursMinutesSeconds,
			expression: "clamp_min(time() - max(" + node("host_observability_lidarr_post_processor_last_success_timestamp_seconds") +
				"), 0) or vector(0)",
			thresholds: absoluteThresholds(
				dashboard.Threshold{Color: "green", Value: nil},
				dashboard.Threshold{Color: "orange", Value: ptr(86400.0)},
			),
		},
	}
	for index, definition := range cueStats {
		placement := cueSummary[index+1]
		builder.WithPanel(valueStat(ValueStatOptions{
			ID: placement.ID, Grid: placement.Grid, Title: definition.title,
			Expression: definition.expression, Legend: "", Unit: definition.unit,
			DataSource: datasource, Thresholds: definition.thresholds,
		}))
	}
	cueSeries := layout.row(8, 12, 12)
	builder.
		WithPanel(timeSeries(TimeseriesOptions{
			ID: cueSeries[0].ID, Grid: cueSeries[0].Grid, Title: "Lidarr Post-Processor Job States",
			Unit: units.Short, DataSource: datasource, Min: ptr(0.0), Stacking: "cue-states", Fill: &fill,
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: node("host_observability_lidarr_post_processor_jobs"), Legend: "{{state}}",
			}},
		})).
		WithPanel(timeSeries(TimeseriesOptions{
			ID: cueSeries[1].ID, Grid: cueSeries[1].Grid, Title: "Lidarr Repair Outcomes",
			Unit: units.Short, DataSource: datasource, Min: ptr(0.0),
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: "increase(" + node("host_observability_lidarr_post_processor_jobs_total") + "[$__rate_interval])", Legend: "{{result}}",
			}},
		}))

	repairSummary := layout.row(5, 6, 6, 6, 6)
	builder.WithPanel(availabilityStat(AvailabilityStatOptions{
		ID: repairSummary[0].ID, Grid: repairSummary[0].Grid, Title: "Radarr Post-Processor Health",
		Expression: "max(" + node("host_observability_radarr_post_processor_ok") + ") or vector(0)",
		Legend:     "health", DataSource: datasource,
	}))
	repairStats := []struct {
		title      string
		expression string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{
			title: "Repair Jobs In Flight",
			expression: "sum(" + node("host_observability_radarr_post_processor_jobs",
				`state=~"settling|agent_starting|agent_running|agent_stopping|ready|importing|awaiting_queue_removal"`) + ") or vector(0)",
			thresholds: absoluteThresholds(
				dashboard.Threshold{Color: "green", Value: nil},
				dashboard.Threshold{Color: "blue", Value: ptr(1.0)},
			),
		},
		{
			title: "Repair Jobs Needing Attention",
			expression: "sum(" + node("host_observability_radarr_post_processor_jobs",
				`state="needs_attention"`) + ") or vector(0)",
			thresholds: greenToRedThreshold(1),
		},
		{
			title: "Successful Repairs",
			expression: "sum(" + node("host_observability_radarr_post_processor_jobs_total",
				`result="success"`) + ") or vector(0)",
			thresholds: absoluteThresholds(dashboard.Threshold{Color: "green", Value: nil}),
		},
	}
	for index, definition := range repairStats {
		placement := repairSummary[index+1]
		builder.WithPanel(valueStat(ValueStatOptions{
			ID: placement.ID, Grid: placement.Grid, Title: definition.title,
			Expression: definition.expression, Legend: "", Unit: units.Short,
			DataSource: datasource, Thresholds: definition.thresholds,
		}))
	}
	repairSeries := layout.row(8, 12, 12)
	builder.
		WithPanel(timeSeries(TimeseriesOptions{
			ID: repairSeries[0].ID, Grid: repairSeries[0].Grid, Title: "Radarr Post-Processor Job States",
			Unit: units.Short, DataSource: datasource, Min: ptr(0.0), Stacking: "repair-states", Fill: &fill,
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: node("host_observability_radarr_post_processor_jobs"), Legend: "{{state}}",
			}},
		})).
		WithPanel(timeSeries(TimeseriesOptions{
			ID: repairSeries[1].ID, Grid: repairSeries[1].Grid, Title: "Radarr Repair Outcomes",
			Unit: units.Short, DataSource: datasource, Min: ptr(0.0),
			Targets: []PrometheusTarget{{
				RefID: "A", Expression: "increase(" + node("host_observability_radarr_post_processor_jobs_total") + "[$__rate_interval])", Legend: "{{result}}",
			}},
		}))

	return builder.Build()
}

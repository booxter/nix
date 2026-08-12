package dashboards

import (
	"fmt"

	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

func LLMOverview(config Config) (dashboard.Dashboard, error) {
	ollamaHost, err := config.serviceHost("ollama")
	if err != nil {
		return dashboard.Dashboard{}, err
	}

	datasource := config.DataSources.Prometheus.reference()
	layout := newPanelLayout()
	metric := func(name string, matchers ...string) string {
		return nodeMetric(name, append([]string{fmt.Sprintf("instance=%q", ollamaHost)}, matchers...)...)
	}

	builder := newDashboard(DashboardOptions{
		Title: "LLM", UID: "llm-stack", Tags: []string{"llm", "gpu", "ollama"},
		From: "now-24h", Refresh: "30s",
	})
	summary := layout.row(5, 8, 8, 8)
	builder.
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: summary[0].ID, Grid: summary[0].Grid, Title: "Ollama API",
			Expression: "max(" + metric("host_observability_ollama_up") + ")",
			Legend:     "API", DataSource: datasource,
		})).
		WithPanel(availabilityStat(AvailabilityStatOptions{
			ID: summary[1].ID, Grid: summary[1].Grid, Title: "GPU Collector",
			Expression: "max(" + metric("host_observability_amdgpu_collector_ok") + ")",
			Legend:     "collector", DataSource: datasource,
		})).
		WithPanel(valueStat(ValueStatOptions{
			ID: summary[2].ID, Grid: summary[2].Grid, Title: "Installed Models",
			Expression: "max(" + metric("host_observability_ollama_models") + ") or vector(0)",
			Legend:     "models", Unit: units.Short, DataSource: datasource,
		}))

	series := []struct {
		title      string
		expression string
		legend     string
		unit       string
		thresholds *dashboard.ThresholdsConfigBuilder
	}{
		{
			title: "GPU Activity", unit: units.Percent, legend: "{{engine}}",
			expression: "max by(engine) (" + metric("host_observability_amdgpu_activity_percent") + ")",
			thresholds: warningCriticalThresholds(80, 95),
		},
		{
			title: "GPU Memory", unit: units.BytesIEC, legend: "{{type}}",
			expression: metric("host_observability_amdgpu_memory_bytes"),
		},
		{
			title: "GPU Temperature", unit: units.Celsius, legend: "{{sensor}}",
			expression: metric("host_observability_amdgpu_temperature_celsius"),
			thresholds: warningCriticalThresholds(80, 90),
		},
		{
			title: "GPU Power", unit: units.Watt, legend: "{{sensor}}",
			expression: metric("host_observability_amdgpu_power_watts"),
		},
		{
			title: "GPU Clocks", unit: units.Hertz, legend: "{{clock}}",
			expression: metric("host_observability_amdgpu_clock_hertz"),
		},
		{
			title: "Loaded Model VRAM", unit: units.BytesIEC, legend: "{{model}}",
			expression: metric("host_observability_ollama_running_model_vram_size_bytes"),
		},
	}
	for offset := 0; offset < len(series); offset += 3 {
		placements := layout.row(8, 8, 8, 8)
		for index, placement := range placements {
			definition := series[offset+index]
			builder.WithPanel(timeSeries(TimeseriesOptions{
				ID: placement.ID, Grid: placement.Grid, Title: definition.title,
				Unit: definition.unit, DataSource: datasource, Min: ptr(0.0),
				Thresholds: definition.thresholds,
				Targets: []PrometheusTarget{{
					RefID: "A", Expression: definition.expression, Legend: definition.legend,
				}},
			}))
		}
	}

	inventory := layout.row(8, 24)[0]
	builder.WithPanel(metricTable(MetricTableOptions{
		ID: inventory.ID, Grid: inventory.Grid, Title: "Ollama Model Inventory",
		Expression: metric("host_observability_ollama_model_info"), Unit: units.Short,
		DataSource: datasource,
	}))

	return builder.Build()
}

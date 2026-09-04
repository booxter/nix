package dashboards

import (
	"testing"

	"github.com/grafana/grafana-foundation-sdk/go/common"
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/prometheus"
	"github.com/grafana/grafana-foundation-sdk/go/stat"
)

func findPanel(t *testing.T, model dashboard.Dashboard, title string) *dashboard.Panel {
	t.Helper()
	for _, item := range model.Panels {
		panel := item.Panel
		if panel != nil && panel.Title != nil && *panel.Title == title {
			return panel
		}
	}
	t.Fatalf("dashboard lacks panel %q", title)
	return nil
}

func TestWanPanelsIncludeClassifiedCountersFromEveryHost(t *testing.T) {
	want := `sum by(instance) (rate(host_observability_network_bytes_total{scrape_profile="node",direction="transmit",scope="wan"}[5m])) * 8`
	tests := []struct {
		name  string
		build func(Config) (dashboard.Dashboard, error)
	}{
		{name: "media", build: MediaOverview},
		{name: "network", build: NetworkOverview},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			model, err := test.build(testConfig)
			if err != nil {
				t.Fatalf("build dashboard: %v", err)
			}
			panel := findPanel(t, model, "WAN Outbound Bandwidth")
			if len(panel.Targets) != 1 {
				t.Fatalf("WAN panel targets = %d, want 1", len(panel.Targets))
			}
			target, ok := panel.Targets[0].(prometheus.Dataquery)
			if !ok {
				t.Fatalf("WAN target type = %T, want prometheus.Dataquery", panel.Targets[0])
			}
			if target.Expr != want {
				t.Errorf("WAN expression = %q, want %q", target.Expr, want)
			}
		})
	}
}

func TestMediaValueStatsLetGrafanaChooseText(t *testing.T) {
	model, err := MediaOverview(testConfig)
	if err != nil {
		t.Fatalf("MediaOverview() error = %v", err)
	}
	panel := findPanel(t, model, "VPN Enforced Cap")
	options, ok := panel.Options.(*stat.Options)
	if !ok {
		t.Fatalf("VPN stat options type = %T, want *stat.Options", panel.Options)
	}
	if options.TextMode != common.BigValueTextModeAuto {
		t.Errorf("VPN stat text mode = %q, want auto", options.TextMode)
	}
}

func TestMediaCategoricalSeriesAreStackedAndFilled(t *testing.T) {
	model, err := MediaOverview(testConfig)
	if err != nil {
		t.Fatalf("MediaOverview() error = %v", err)
	}
	titles := []string{
		"Transmission Upload Throughput By Torrent Priority",
		"Transmission Download Throughput By Torrent Priority",
		"Transmission Upload Peers By Torrent Priority",
		"Transmission Download Peers By Torrent Priority",
		"Transmission Seeding Torrents",
		"Transmission Downloading Torrents",
	}
	for _, title := range titles {
		t.Run(title, func(t *testing.T) {
			panel := findPanel(t, model, title)
			custom, ok := panel.FieldConfig.Defaults.Custom.(*common.GraphFieldConfig)
			if !ok {
				t.Fatalf("field config type = %T, want *common.GraphFieldConfig", panel.FieldConfig.Defaults.Custom)
			}
			if custom.Stacking == nil || custom.Stacking.Mode == nil || *custom.Stacking.Mode != common.StackingModeNormal {
				t.Errorf("stacking = %#v, want normal", custom.Stacking)
			}
			if custom.FillOpacity == nil || *custom.FillOpacity != 20 {
				t.Errorf("fill opacity = %v, want 20", custom.FillOpacity)
			}
		})
	}

}

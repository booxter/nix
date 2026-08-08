package dashboards

import (
	"fmt"
	"strings"

	"github.com/grafana/grafana-foundation-sdk/go/common"
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/prometheus"
	"github.com/grafana/grafana-foundation-sdk/go/stat"
	"github.com/grafana/grafana-foundation-sdk/go/timeseries"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

const physicalInterfaceExclusion = `lo|usb.*|veth.*|docker.*|br-.*|virbr.*|vnet.*|zt.*|tailscale.*|wg.*|tun.*`

type DashboardOptions struct {
	Title   string
	UID     string
	Tags    []string
	From    string
	Refresh string
}

func newDashboard(options DashboardOptions) *dashboard.DashboardBuilder {
	return dashboard.NewDashboardBuilder(options.Title).
		Uid(options.UID).
		Tags(options.Tags).
		Readonly().
		Timezone(common.TimeZoneBrowser).
		Refresh(options.Refresh).
		Time(options.From, "now")
}

func ptr[T any](value T) *T {
	return &value
}

func grid(x, y, width, height uint32) dashboard.GridPos {
	return dashboard.GridPos{X: x, Y: y, W: width, H: height}
}

func absoluteThresholds(steps ...dashboard.Threshold) *dashboard.ThresholdsConfigBuilder {
	return dashboard.NewThresholdsConfigBuilder().
		Mode(dashboard.ThresholdsModeAbsolute).
		Steps(steps)
}

func redToGreenThreshold(value float64) *dashboard.ThresholdsConfigBuilder {
	return absoluteThresholds(
		dashboard.Threshold{Color: "red", Value: nil},
		dashboard.Threshold{Color: "green", Value: ptr(value)},
	)
}

func greenToRedThreshold(value float64) *dashboard.ThresholdsConfigBuilder {
	return absoluteThresholds(
		dashboard.Threshold{Color: "green", Value: nil},
		dashboard.Threshold{Color: "red", Value: ptr(value)},
	)
}

func warningCriticalThresholds(warning, critical float64) *dashboard.ThresholdsConfigBuilder {
	return absoluteThresholds(
		dashboard.Threshold{Color: "green", Value: nil},
		dashboard.Threshold{Color: "orange", Value: ptr(warning)},
		dashboard.Threshold{Color: "red", Value: ptr(critical)},
	)
}

func availabilityMapping() dashboard.ValueMapping {
	return exactValueMapping(map[string]dashboard.ValueMappingResult{
		"0": mappedValue("Down", "red", 0),
		"1": mappedValue("Up", "green", 1),
	})
}

func mappedValue(text, color string, index int32) dashboard.ValueMappingResult {
	return dashboard.ValueMappingResult{Color: ptr(color), Text: ptr(text), Index: ptr(index)}
}

func exactValueMapping(values map[string]dashboard.ValueMappingResult) dashboard.ValueMapping {
	valueMap := dashboard.NewValueMap()
	valueMap.Options = values
	return dashboard.ValueMapping{ValueMap: valueMap}
}

func applicationMetric(metric, service string, matchers ...string) string {
	labels := []string{`scrape_profile="application"`, fmt.Sprintf("service=%q", service)}
	labels = append(labels, matchers...)
	return fmt.Sprintf("%s{%s}", metric, strings.Join(labels, ","))
}

func nodeMetric(metric string, matchers ...string) string {
	labels := append([]string{`scrape_profile="node"`}, matchers...)
	return fmt.Sprintf("%s{%s}", metric, strings.Join(labels, ","))
}

func prometheusQuery(refID, expression, legend string, instant bool) *prometheus.DataqueryBuilder {
	query := prometheus.NewDataqueryBuilder().
		RefId(refID).
		Expr(expression).
		LegendFormat(legend).
		EditorMode(prometheus.QueryEditorModeCode)
	if instant {
		return query.Instant()
	}
	return query.Range()
}

type AvailabilityStatOptions struct {
	ID         uint32
	Title      string
	Expression string
	Legend     string
	Grid       dashboard.GridPos
	DataSource common.DataSourceRef
}

func availabilityStat(options AvailabilityStatOptions) *stat.PanelBuilder {
	return stat.NewPanelBuilder().
		Id(options.ID).
		Title(options.Title).
		Datasource(options.DataSource).
		GridPos(options.Grid).
		Unit(units.Short).
		Min(0).
		Max(1).
		ColorMode(common.BigValueColorModeBackground).
		GraphMode(common.BigValueGraphModeNone).
		TextMode(common.BigValueTextModeValueAndName).
		Orientation(common.VizOrientationAuto).
		WideLayout(true).
		ShowPercentChange(false).
		ReduceOptions(common.NewReduceDataOptionsBuilder().
			Values(false).
			Calcs([]string{"lastNotNull"}).
			Fields("")).
		Thresholds(redToGreenThreshold(1)).
		Mappings([]dashboard.ValueMapping{availabilityMapping()}).
		WithTarget(prometheusQuery("A", options.Expression, options.Legend, true))
}

type ValueStatOptions struct {
	ID         uint32
	Title      string
	Expression string
	Legend     string
	Unit       string
	Grid       dashboard.GridPos
	DataSource common.DataSourceRef
	Min        *float64
	Max        *float64
	Mappings   []dashboard.ValueMapping
	Background bool
	Thresholds *dashboard.ThresholdsConfigBuilder
}

func valueStat(options ValueStatOptions) *stat.PanelBuilder {
	panel := stat.NewPanelBuilder().
		Id(options.ID).
		Title(options.Title).
		Datasource(options.DataSource).
		GridPos(options.Grid).
		Unit(options.Unit).
		TextMode(common.BigValueTextModeValueAndName).
		Orientation(common.VizOrientationAuto).
		ReduceOptions(common.NewReduceDataOptionsBuilder().
			Values(false).
			Calcs([]string{"lastNotNull"}).
			Fields("")).
		WithTarget(prometheusQuery("A", options.Expression, options.Legend, true))
	if options.Background {
		panel.ColorMode(common.BigValueColorModeBackground).
			GraphMode(common.BigValueGraphModeNone)
	} else {
		panel.ColorMode(common.BigValueColorModeValue).
			GraphMode(common.BigValueGraphModeArea)
	}
	if options.Min != nil {
		panel.Min(*options.Min)
	}
	if options.Max != nil {
		panel.Max(*options.Max)
	}
	if options.Mappings != nil {
		panel.Mappings(options.Mappings)
	}
	if options.Thresholds != nil {
		panel.Thresholds(options.Thresholds)
	}
	return panel
}

type PrometheusTarget struct {
	RefID      string
	Expression string
	Legend     string
}

type TimeseriesOptions struct {
	ID             uint32
	Title          string
	Unit           string
	Grid           dashboard.GridPos
	DataSource     common.DataSourceRef
	Min            *float64
	Max            *float64
	Mappings       []dashboard.ValueMapping
	Thresholds     *dashboard.ThresholdsConfigBuilder
	Targets        []PrometheusTarget
	Stacking       string
	Fill           *float64
	SoftMax        *float64
	ShowThresholds bool
}

func timeSeries(options TimeseriesOptions) *timeseries.PanelBuilder {
	panel := timeseries.NewPanelBuilder().
		Id(options.ID).
		Title(options.Title).
		Datasource(options.DataSource).
		GridPos(options.Grid).
		Unit(options.Unit).
		Legend(common.NewVizLegendOptionsBuilder().
			DisplayMode(common.LegendDisplayModeList).
			Placement(common.LegendPlacementBottom).
			ShowLegend(true)).
		Tooltip(common.NewVizTooltipOptionsBuilder().
			Mode(common.TooltipDisplayModeMulti).
			Sort(common.SortOrderDescending))
	if options.Min != nil {
		panel.Min(*options.Min)
	}
	if options.Max != nil {
		panel.Max(*options.Max)
	}
	if options.Mappings != nil {
		panel.Mappings(options.Mappings)
	}
	if options.Thresholds != nil {
		panel.Thresholds(options.Thresholds)
	}
	if options.Stacking != "" {
		panel.Stacking(common.NewStackingConfigBuilder().
			Mode(common.StackingModeNormal).
			Group(options.Stacking))
	}
	if options.Fill != nil {
		panel.FillOpacity(*options.Fill)
	}
	if options.SoftMax != nil {
		panel.AxisSoftMax(*options.SoftMax)
	}
	if options.ShowThresholds {
		panel.ThresholdsStyle(common.NewGraphThresholdsStyleConfigBuilder().
			Mode(common.GraphThresholdsStyleModeLine))
	}
	for _, target := range options.Targets {
		panel.WithTarget(prometheusQuery(target.RefID, target.Expression, target.Legend, false))
	}
	return panel
}

type panelPlacement struct {
	ID   uint32
	Grid dashboard.GridPos
}

type panelLayout struct {
	nextID uint32
	y      uint32
}

func newPanelLayout() *panelLayout {
	return &panelLayout{nextID: 1}
}

func (layout *panelLayout) row(height uint32, widths ...uint32) []panelPlacement {
	placements := make([]panelPlacement, 0, len(widths))
	var x uint32
	for _, width := range widths {
		placements = append(placements, panelPlacement{
			ID:   layout.nextID,
			Grid: grid(x, layout.y, width, height),
		})
		layout.nextID++
		x += width
	}
	if x != 24 {
		panic(fmt.Sprintf("panel row width is %d, want 24", x))
	}
	layout.y += height
	return placements
}

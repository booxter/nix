package dashboards

import (
	"fmt"

	"github.com/grafana/grafana-foundation-sdk/go/common"
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/prometheus"
	"github.com/grafana/grafana-foundation-sdk/go/stat"
	"github.com/grafana/grafana-foundation-sdk/go/timeseries"
	"github.com/grafana/grafana-foundation-sdk/go/units"
)

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

func availabilityMapping() dashboard.ValueMapping {
	valueMap := dashboard.NewValueMap()
	valueMap.Options = map[string]dashboard.ValueMappingResult{
		"0": {Color: ptr("red"), Text: ptr("Down"), Index: ptr(int32(0))},
		"1": {Color: ptr("green"), Text: ptr("Up"), Index: ptr(int32(1))},
	}
	return dashboard.ValueMapping{ValueMap: valueMap}
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
	Thresholds *dashboard.ThresholdsConfigBuilder
}

func valueStat(options ValueStatOptions) *stat.PanelBuilder {
	panel := stat.NewPanelBuilder().
		Id(options.ID).
		Title(options.Title).
		Datasource(options.DataSource).
		GridPos(options.Grid).
		Unit(options.Unit).
		ColorMode(common.BigValueColorModeValue).
		GraphMode(common.BigValueGraphModeArea).
		TextMode(common.BigValueTextModeValueAndName).
		Orientation(common.VizOrientationAuto).
		ReduceOptions(common.NewReduceDataOptionsBuilder().
			Values(false).
			Calcs([]string{"lastNotNull"}).
			Fields("")).
		WithTarget(prometheusQuery("A", options.Expression, options.Legend, true))
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
	ID         uint32
	Title      string
	Unit       string
	Grid       dashboard.GridPos
	DataSource common.DataSourceRef
	Min        *float64
	Max        *float64
	Mappings   []dashboard.ValueMapping
	Thresholds *dashboard.ThresholdsConfigBuilder
	Targets    []PrometheusTarget
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

package dashboards

import (
	"github.com/grafana/grafana-foundation-sdk/go/common"
	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
	"github.com/grafana/grafana-foundation-sdk/go/prometheus"
	"github.com/grafana/grafana-foundation-sdk/go/stat"
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
	Y          uint32
	Title      string
	Expression string
	Legend     string
	DataSource common.DataSourceRef
}

func availabilityStat(options AvailabilityStatOptions) *stat.PanelBuilder {
	return stat.NewPanelBuilder().
		Id(options.ID).
		Title(options.Title).
		Datasource(options.DataSource).
		GridPos(grid(0, options.Y, 24, 8)).
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

package prometheus

import (
	"io"
	"math"

	dto "github.com/prometheus/client_model/go"
	"github.com/prometheus/common/expfmt"
	"github.com/prometheus/common/model"
)

func ParseText(reader io.Reader) (map[string]*dto.MetricFamily, error) {
	parser := expfmt.NewTextParser(model.UTF8Validation)
	return parser.TextToMetricFamilies(reader)
}

func Metrics(family *dto.MetricFamily) []*dto.Metric {
	if family == nil {
		return nil
	}
	return family.GetMetric()
}

func FamilyValue(family *dto.MetricFamily, requiredLabels map[string]string) float64 {
	for _, metric := range Metrics(family) {
		labels := Labels(metric)
		matches := true
		for name, expected := range requiredLabels {
			if labels[name] != expected {
				matches = false
				break
			}
		}
		if matches {
			return Value(metric)
		}
	}
	return math.NaN()
}

func Value(metric *dto.Metric) float64 {
	switch {
	case metric.Gauge != nil:
		return metric.GetGauge().GetValue()
	case metric.Counter != nil:
		return metric.GetCounter().GetValue()
	case metric.Untyped != nil:
		return metric.GetUntyped().GetValue()
	default:
		return math.NaN()
	}
}

func Labels(metric *dto.Metric) map[string]string {
	result := make(map[string]string, len(metric.GetLabel()))
	for _, pair := range metric.GetLabel() {
		result[pair.GetName()] = pair.GetValue()
	}
	return result
}

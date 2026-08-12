package prometheus

import (
	"math"
	"strings"
	"testing"
)

func TestParseTextExposesLabelsAndMetricValues(t *testing.T) {
	families, err := ParseText(strings.NewReader(`# TYPE sample gauge
sample{direction="receive",scope="wan"} 42.5
sample{direction="transmit",scope="wan"} 7
`))
	if err != nil {
		t.Fatalf("ParseText returned an error: %v", err)
	}
	if got := FamilyValue(families["sample"], map[string]string{
		"direction": "receive",
		"scope":     "wan",
	}); got != 42.5 {
		t.Errorf("FamilyValue = %v, want 42.5", got)
	}
	if got := FamilyValue(families["sample"], map[string]string{"scope": "missing"}); !math.IsNaN(got) {
		t.Errorf("missing FamilyValue = %v, want NaN", got)
	}
}

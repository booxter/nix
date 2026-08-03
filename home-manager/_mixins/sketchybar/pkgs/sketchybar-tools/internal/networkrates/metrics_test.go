package networkrates

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testMetrics = `# TYPE host_observability_network_bytes_per_second gauge
host_observability_network_bytes_per_second{direction="receive",scope="lan"} 900
host_observability_network_bytes_per_second{direction="receive",scope="wan"} 1536
host_observability_network_bytes_per_second{direction="transmit",scope="wan"} 2621440
`

func TestParseRatesSelectsDirectionAndScope(t *testing.T) {
	rates, err := ParseRates(strings.NewReader(testMetrics), "wan")
	if err != nil {
		t.Fatalf("ParseRates returned an error: %v", err)
	}
	if rates != (Rates{Down: 1536, Up: 2621440}) {
		t.Fatalf("ParseRates = %#v", rates)
	}
	if _, err := ParseRates(strings.NewReader(testMetrics), "lan"); err == nil {
		t.Fatal("incomplete scope should fail")
	}
}

func TestNativeMetricsProviderRequiresFreshMetrics(t *testing.T) {
	metricsFile := filepath.Join(t.TempDir(), "lan-wan.prom")
	if err := os.WriteFile(metricsFile, []byte(testMetrics), 0o600); err != nil {
		t.Fatalf("write metrics: %v", err)
	}
	now := time.Unix(1_700_000_000, 0)
	if err := os.Chtimes(metricsFile, now.Add(-30*time.Second), now.Add(-30*time.Second)); err != nil {
		t.Fatalf("set metrics timestamp: %v", err)
	}
	config := Config{MetricsFile: metricsFile, Scope: "wan", MetricsMaxAgeSeconds: 90}
	if _, err := (NativeMetricsProvider{}).Rates(config, now); err != nil {
		t.Fatalf("fresh metrics failed: %v", err)
	}
	if _, err := (NativeMetricsProvider{}).Rates(config, now.Add(2*time.Minute)); err == nil {
		t.Fatal("stale metrics should fail")
	}
	if _, err := (NativeMetricsProvider{}).Rates(config, now.Add(-time.Minute)); err == nil {
		t.Fatal("future metrics should fail")
	}
}

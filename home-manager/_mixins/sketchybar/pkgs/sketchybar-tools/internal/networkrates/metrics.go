package networkrates

import (
	"fmt"
	"io"
	"math"
	"os"
	"time"

	prometheusmetrics "github.com/booxter/nix-config/sketchybar-tools/internal/prometheus"
)

const rateMetricName = "host_observability_network_bytes_per_second"

type Rates struct {
	Down float64
	Up   float64
}

type MetricsProvider interface {
	Rates(config Config, now time.Time) (Rates, error)
}

type NativeMetricsProvider struct{}

func (NativeMetricsProvider) Rates(config Config, now time.Time) (Rates, error) {
	info, err := os.Stat(config.MetricsFile)
	if err != nil {
		return Rates{}, fmt.Errorf("stat network metrics: %w", err)
	}
	age := now.Sub(info.ModTime())
	if age < 0 || age > time.Duration(config.MetricsMaxAgeSeconds)*time.Second {
		return Rates{}, fmt.Errorf("network metrics are stale")
	}
	file, err := os.Open(config.MetricsFile)
	if err != nil {
		return Rates{}, fmt.Errorf("open network metrics: %w", err)
	}
	defer file.Close()
	return ParseRates(file, config.Scope)
}

func ParseRates(reader io.Reader, scope string) (Rates, error) {
	families, err := prometheusmetrics.ParseText(reader)
	if err != nil {
		return Rates{}, fmt.Errorf("parse network metrics: %w", err)
	}
	family := families[rateMetricName]
	down := prometheusmetrics.FamilyValue(family, map[string]string{
		"direction": "receive",
		"scope":     scope,
	})
	up := prometheusmetrics.FamilyValue(family, map[string]string{
		"direction": "transmit",
		"scope":     scope,
	})
	if math.IsNaN(down) || math.IsNaN(up) {
		return Rates{}, fmt.Errorf("network rate metrics for scope %q are incomplete", scope)
	}
	return Rates{Down: down, Up: up}, nil
}

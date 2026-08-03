package networkrates

import (
	"fmt"
	"strconv"
)

const (
	defaultMetricsFile          = "/var/lib/prometheus-node-exporter-textfile/lan-wan.prom"
	defaultMetricsMaxAgeSeconds = 90
	defaultScope                = "wan"
)

type Config struct {
	Scope                string
	MetricsFile          string
	MetricsMaxAgeSeconds int
	SketchybarExecutable string
}

func ConfigFromEnvironment(getenv func(string) string) (Config, error) {
	config := Config{
		Scope:                getenv("NETWORK_SCOPE"),
		MetricsFile:          getenv("LAN_WAN_METRICS_FILE"),
		MetricsMaxAgeSeconds: defaultMetricsMaxAgeSeconds,
		SketchybarExecutable: getenv("SKETCHYBAR_BIN"),
	}
	if config.Scope == "" {
		config.Scope = defaultScope
	}
	if config.MetricsFile == "" {
		config.MetricsFile = defaultMetricsFile
	}
	if rawMaxAge := getenv("LAN_WAN_METRICS_MAX_AGE_SECONDS"); rawMaxAge != "" {
		value, err := strconv.Atoi(rawMaxAge)
		if err == nil && value >= 0 {
			config.MetricsMaxAgeSeconds = value
		}
	}
	if config.SketchybarExecutable == "" {
		return Config{}, fmt.Errorf("missing environment setting SKETCHYBAR_BIN")
	}
	return config, nil
}

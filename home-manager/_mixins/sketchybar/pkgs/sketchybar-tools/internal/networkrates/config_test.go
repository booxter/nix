package networkrates

import "testing"

func TestConfigFromEnvironmentAppliesDefaultsAndOverrides(t *testing.T) {
	values := map[string]string{"SKETCHYBAR_BIN": "/sketchybar"}
	config, err := ConfigFromEnvironment(func(name string) string { return values[name] })
	if err != nil {
		t.Fatalf("ConfigFromEnvironment returned an error: %v", err)
	}
	if config.Scope != defaultScope || config.MetricsFile != defaultMetricsFile || config.MetricsMaxAgeSeconds != 90 {
		t.Fatalf("default configuration = %#v", config)
	}

	values["NETWORK_SCOPE"] = "lan"
	values["LAN_WAN_METRICS_FILE"] = "/metrics"
	values["LAN_WAN_METRICS_MAX_AGE_SECONDS"] = "15"
	config, err = ConfigFromEnvironment(func(name string) string { return values[name] })
	if err != nil {
		t.Fatalf("ConfigFromEnvironment returned an error: %v", err)
	}
	if config.Scope != "lan" || config.MetricsFile != "/metrics" || config.MetricsMaxAgeSeconds != 15 {
		t.Fatalf("overridden configuration = %#v", config)
	}
}

func TestConfigFromEnvironmentRejectsMissingExecutableAndIgnoresInvalidAge(t *testing.T) {
	values := map[string]string{
		"SKETCHYBAR_BIN":                  "/sketchybar",
		"LAN_WAN_METRICS_MAX_AGE_SECONDS": "-1",
	}
	config, err := ConfigFromEnvironment(func(name string) string { return values[name] })
	if err != nil {
		t.Fatalf("ConfigFromEnvironment returned an error: %v", err)
	}
	if config.MetricsMaxAgeSeconds != defaultMetricsMaxAgeSeconds {
		t.Fatalf("invalid age produced %d", config.MetricsMaxAgeSeconds)
	}
	delete(values, "SKETCHYBAR_BIN")
	if _, err := ConfigFromEnvironment(func(name string) string { return values[name] }); err == nil {
		t.Fatal("missing SketchyBar executable should fail")
	}
}

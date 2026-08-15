package alertmanager

import "testing"

func TestConfigFromEnvironmentAppliesColorsAndValidatesSettings(t *testing.T) {
	values := map[string]string{
		"NAME":                            "alertmanager",
		"ALERTMANAGER_URL":                "https://alertmanager.test/api/v2/alerts",
		"ALERTMANAGER_CA_CERTIFICATE":     "/ca",
		"ALERTMANAGER_CLIENT_CERTIFICATE": "/cert",
		"ALERTMANAGER_CLIENT_KEY":         "/key",
		"SKETCHYBAR_BIN":                  "/sketchybar",
		"SKETCHYBAR_COLOR_RED":            "red",
		"SKETCHYBAR_COLOR_YELLOW":         "yellow",
	}
	config, err := ConfigFromEnvironment(func(name string) string { return values[name] })
	if err != nil {
		t.Fatalf("ConfigFromEnvironment returned an error: %v", err)
	}
	if config.Red != "red" || config.Yellow != "yellow" {
		t.Fatalf("configured colors were not retained: %#v", config)
	}
	delete(values, "ALERTMANAGER_URL")
	if _, err := ConfigFromEnvironment(func(name string) string { return values[name] }); err == nil {
		t.Fatal("missing URL should fail")
	}
}

func TestConfigFromEnvironmentUsesDefaultColors(t *testing.T) {
	values := map[string]string{
		"NAME":                            "alertmanager",
		"ALERTMANAGER_URL":                "https://alertmanager.test/api/v2/alerts",
		"ALERTMANAGER_CA_CERTIFICATE":     "/ca",
		"ALERTMANAGER_CLIENT_CERTIFICATE": "/cert",
		"ALERTMANAGER_CLIENT_KEY":         "/key",
		"SKETCHYBAR_BIN":                  "/sketchybar",
	}
	config, err := ConfigFromEnvironment(func(name string) string { return values[name] })
	if err != nil {
		t.Fatalf("ConfigFromEnvironment returned an error: %v", err)
	}
	if config.Red != defaultRed || config.Yellow != defaultYellow {
		t.Fatalf("default colors were not applied: %#v", config)
	}
}

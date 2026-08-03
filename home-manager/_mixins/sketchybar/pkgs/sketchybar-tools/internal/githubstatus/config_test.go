package githubstatus

import "testing"

func TestConfigFromEnvironmentAppliesColorAndValidatesSettings(t *testing.T) {
	values := map[string]string{
		"NAME":                 "github-status",
		"GITHUB_STATUS_URL":    "https://github-status.test/api/v2/summary.json",
		"SKETCHYBAR_BIN":       "/sketchybar",
		"SKETCHYBAR_COLOR_RED": "red",
	}
	config, err := ConfigFromEnvironment(func(name string) string { return values[name] })
	if err != nil {
		t.Fatalf("ConfigFromEnvironment returned an error: %v", err)
	}
	if config.Red != "red" {
		t.Fatalf("configured color was not retained: %#v", config)
	}
	delete(values, "NAME")
	if _, err := ConfigFromEnvironment(func(name string) string { return values[name] }); err == nil {
		t.Fatal("missing name should fail")
	}
}

func TestConfigFromEnvironmentUsesDefaultColor(t *testing.T) {
	values := map[string]string{
		"NAME":              "github-status",
		"GITHUB_STATUS_URL": "https://github-status.test/api/v2/summary.json",
		"SKETCHYBAR_BIN":    "/sketchybar",
	}
	config, err := ConfigFromEnvironment(func(name string) string { return values[name] })
	if err != nil {
		t.Fatalf("ConfigFromEnvironment returned an error: %v", err)
	}
	if config.Red != defaultRed {
		t.Fatalf("default color was not applied: %#v", config)
	}
}

package jellyfin

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigFromEnvironmentAppliesColorsAndValidatesSettings(t *testing.T) {
	values := map[string]string{
		"NAME":                        "jellyfin",
		"JELLYFIN_METRICS_URL":        "https://jellyfin.test/metrics",
		"JELLYFIN_CA_CERTIFICATE":     "/ca",
		"JELLYFIN_CLIENT_CERTIFICATE": "/cert",
		"JELLYFIN_CLIENT_KEY":         "/key",
		"SKETCHYBAR_BIN":              "/sketchybar",
		"SKETCHYBAR_COLOR_PURPLE":     "purple",
		"SKETCHYBAR_COLOR_YELLOW":     "yellow",
	}
	config, err := ConfigFromEnvironment(func(name string) string { return values[name] })
	if err != nil {
		t.Fatalf("ConfigFromEnvironment returned an error: %v", err)
	}
	if config.Purple != "purple" || config.Yellow != "yellow" {
		t.Fatalf("configured colors were not retained: %#v", config)
	}
	delete(values, "NAME")
	if _, err := ConfigFromEnvironment(func(name string) string { return values[name] }); err == nil {
		t.Fatal("missing name should fail")
	}
}

func TestHTTPFetcherRejectsInvalidCAWithoutNetworkAccess(t *testing.T) {
	directory := t.TempDir()
	caPath := filepath.Join(directory, "ca.pem")
	if err := os.WriteFile(caPath, []byte("not a certificate"), 0o600); err != nil {
		t.Fatalf("write CA fixture: %v", err)
	}
	config := testConfig()
	config.CACertificate = caPath
	_, err := NewHTTPMetricsFetcher(config).Fetch(context.Background())
	if err == nil || !strings.Contains(err.Error(), "contains no certificates") {
		t.Fatalf("unexpected error: %v", err)
	}
}

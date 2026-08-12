package stock

import (
	"strings"
	"testing"
)

func environment(values map[string]string) func(string) string {
	return func(name string) string { return values[name] }
}

func TestConfigFromEnvironmentUsesDefaults(t *testing.T) {
	config, err := ConfigFromEnvironment(environment(map[string]string{
		"NAME":           "stock",
		"STOCK_API_URL":  "https://stock.test/api/quote",
		"SKETCHYBAR_BIN": "/sketchybar",
	}))
	if err != nil {
		t.Fatalf("ConfigFromEnvironment returned an error: %v", err)
	}
	if config.Symbol != defaultSymbol {
		t.Errorf("Symbol = %q, want %q", config.Symbol, defaultSymbol)
	}
	if config.Green != defaultGreen || config.Red != defaultRed || config.Yellow != defaultYellow {
		t.Errorf("unexpected default colors: %#v", config)
	}
}

func TestConfigFromEnvironmentRequiresRuntimeSettings(t *testing.T) {
	for _, name := range []string{"NAME", "STOCK_API_URL", "SKETCHYBAR_BIN"} {
		values := map[string]string{
			"NAME":           "stock",
			"STOCK_API_URL":  "https://stock.test/api/quote",
			"SKETCHYBAR_BIN": "/sketchybar",
		}
		delete(values, name)
		_, err := ConfigFromEnvironment(environment(values))
		if err == nil || !strings.Contains(err.Error(), name) {
			t.Errorf("missing %s returned error %v", name, err)
		}
	}
}

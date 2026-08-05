package volume

import (
	"strings"
	"testing"
)

func TestConfigFromEnvironmentRequiresRuntimeSettings(t *testing.T) {
	for _, name := range []string{"NAME", "SKETCHYBAR_BIN"} {
		values := map[string]string{
			"NAME":           "volume",
			"SKETCHYBAR_BIN": "/sketchybar",
		}
		delete(values, name)
		_, err := ConfigFromEnvironment(func(key string) string { return values[key] })
		if err == nil || !strings.Contains(err.Error(), name) {
			t.Errorf("missing %s returned error %v", name, err)
		}
	}
}

package statuspage

import (
	"encoding/json"
	"fmt"
)

const defaultRed = "0xfffb4934"

type Config struct {
	Name                 string
	URL                  string
	Icon                 string
	Components           []string
	Red                  string
	SketchybarExecutable string
}

func ConfigFromEnvironment(getenv func(string) string) (Config, error) {
	config := Config{
		Name:                 getenv("NAME"),
		URL:                  getenv("STATUSPAGE_URL"),
		Icon:                 getenv("STATUSPAGE_ICON"),
		Red:                  getenv("SKETCHYBAR_COLOR_RED"),
		SketchybarExecutable: getenv("SKETCHYBAR_BIN"),
	}
	if config.Red == "" {
		config.Red = defaultRed
	}
	if components := getenv("STATUSPAGE_COMPONENTS"); components != "" {
		if err := json.Unmarshal([]byte(components), &config.Components); err != nil {
			return Config{}, fmt.Errorf("decode STATUSPAGE_COMPONENTS: %w", err)
		}
	}

	required := []struct {
		name  string
		value string
	}{
		{"NAME", config.Name},
		{"STATUSPAGE_URL", config.URL},
		{"STATUSPAGE_ICON", config.Icon},
		{"SKETCHYBAR_BIN", config.SketchybarExecutable},
	}
	for _, setting := range required {
		if setting.value == "" {
			return Config{}, fmt.Errorf("missing environment setting %s", setting.name)
		}
	}
	return config, nil
}

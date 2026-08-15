package stock

import "fmt"

const (
	defaultSymbol = "NVDA"
	defaultGreen  = "0xffb8bb26"
	defaultRed    = "0xfffb4934"
	defaultYellow = "0xfffabd2f"
)

type Config struct {
	Name                 string
	Symbol               string
	APIURL               string
	Green                string
	Red                  string
	Yellow               string
	SketchybarExecutable string
}

func ConfigFromEnvironment(getenv func(string) string) (Config, error) {
	config := Config{
		Name:                 getenv("NAME"),
		Symbol:               getenv("STOCK_SYMBOL"),
		APIURL:               getenv("STOCK_API_URL"),
		Green:                getenv("SKETCHYBAR_COLOR_GREEN"),
		Red:                  getenv("SKETCHYBAR_COLOR_RED"),
		Yellow:               getenv("SKETCHYBAR_COLOR_YELLOW"),
		SketchybarExecutable: getenv("SKETCHYBAR_BIN"),
	}
	if config.Symbol == "" {
		config.Symbol = defaultSymbol
	}
	if config.Green == "" {
		config.Green = defaultGreen
	}
	if config.Red == "" {
		config.Red = defaultRed
	}
	if config.Yellow == "" {
		config.Yellow = defaultYellow
	}

	required := []struct {
		name  string
		value string
	}{
		{"NAME", config.Name},
		{"STOCK_API_URL", config.APIURL},
		{"SKETCHYBAR_BIN", config.SketchybarExecutable},
	}
	for _, setting := range required {
		if setting.value == "" {
			return Config{}, fmt.Errorf("missing environment setting %s", setting.name)
		}
	}
	return config, nil
}

package diskspace

import "fmt"

type Config struct {
	Name                 string
	Home                 string
	SketchybarExecutable string
}

func ConfigFromEnvironment(getenv func(string) string) (Config, error) {
	config := Config{
		Name:                 getenv("NAME"),
		Home:                 getenv("HOME"),
		SketchybarExecutable: getenv("SKETCHYBAR_BIN"),
	}
	required := []struct {
		name  string
		value string
	}{
		{"NAME", config.Name},
		{"HOME", config.Home},
		{"SKETCHYBAR_BIN", config.SketchybarExecutable},
	}
	for _, setting := range required {
		if setting.value == "" {
			return Config{}, fmt.Errorf("missing environment setting %s", setting.name)
		}
	}
	return config, nil
}

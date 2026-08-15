package volume

import "fmt"

type Config struct {
	Name                 string
	Sender               string
	Volume               string
	SketchybarExecutable string
}

func ConfigFromEnvironment(getenv func(string) string) (Config, error) {
	config := Config{
		Name:                 getenv("NAME"),
		Sender:               getenv("SENDER"),
		Volume:               getenv("INFO"),
		SketchybarExecutable: getenv("SKETCHYBAR_BIN"),
	}
	for _, setting := range []struct {
		name  string
		value string
	}{
		{"NAME", config.Name},
		{"SKETCHYBAR_BIN", config.SketchybarExecutable},
	} {
		if setting.value == "" {
			return Config{}, fmt.Errorf("missing environment setting %s", setting.name)
		}
	}
	return config, nil
}

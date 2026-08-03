package alertmanager

import "fmt"

const (
	defaultRed    = "0xfffb4934"
	defaultYellow = "0xfffabd2f"
)

type Config struct {
	Name                 string
	URL                  string
	CACertificate        string
	ClientCertificate    string
	ClientKey            string
	Red                  string
	Yellow               string
	SketchybarExecutable string
}

func ConfigFromEnvironment(getenv func(string) string) (Config, error) {
	config := Config{
		Name:                 getenv("NAME"),
		URL:                  getenv("ALERTMANAGER_URL"),
		CACertificate:        getenv("ALERTMANAGER_CA_CERTIFICATE"),
		ClientCertificate:    getenv("ALERTMANAGER_CLIENT_CERTIFICATE"),
		ClientKey:            getenv("ALERTMANAGER_CLIENT_KEY"),
		Red:                  getenv("SKETCHYBAR_COLOR_RED"),
		Yellow:               getenv("SKETCHYBAR_COLOR_YELLOW"),
		SketchybarExecutable: getenv("SKETCHYBAR_BIN"),
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
		{"ALERTMANAGER_URL", config.URL},
		{"ALERTMANAGER_CA_CERTIFICATE", config.CACertificate},
		{"ALERTMANAGER_CLIENT_CERTIFICATE", config.ClientCertificate},
		{"ALERTMANAGER_CLIENT_KEY", config.ClientKey},
		{"SKETCHYBAR_BIN", config.SketchybarExecutable},
	}
	for _, setting := range required {
		if setting.value == "" {
			return Config{}, fmt.Errorf("missing environment setting %s", setting.name)
		}
	}
	return config, nil
}

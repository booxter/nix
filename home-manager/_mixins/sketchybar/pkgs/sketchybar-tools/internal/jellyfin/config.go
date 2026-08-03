package jellyfin

import "fmt"

const (
	defaultPurple = "0xffd3869b"
	defaultYellow = "0xfffabd2f"
)

type Config struct {
	Name                 string
	Sender               string
	MetricsURL           string
	CACertificate        string
	ClientCertificate    string
	ClientKey            string
	Purple               string
	Yellow               string
	SketchybarExecutable string
}

func ConfigFromEnvironment(getenv func(string) string) (Config, error) {
	config := Config{
		Name:                 getenv("NAME"),
		Sender:               getenv("SENDER"),
		MetricsURL:           getenv("JELLYFIN_METRICS_URL"),
		CACertificate:        getenv("JELLYFIN_CA_CERTIFICATE"),
		ClientCertificate:    getenv("JELLYFIN_CLIENT_CERTIFICATE"),
		ClientKey:            getenv("JELLYFIN_CLIENT_KEY"),
		Purple:               getenv("SKETCHYBAR_COLOR_PURPLE"),
		Yellow:               getenv("SKETCHYBAR_COLOR_YELLOW"),
		SketchybarExecutable: getenv("SKETCHYBAR_BIN"),
	}
	if config.Purple == "" {
		config.Purple = defaultPurple
	}
	if config.Yellow == "" {
		config.Yellow = defaultYellow
	}

	required := []struct {
		name  string
		value string
	}{
		{"NAME", config.Name},
		{"JELLYFIN_METRICS_URL", config.MetricsURL},
		{"JELLYFIN_CA_CERTIFICATE", config.CACertificate},
		{"JELLYFIN_CLIENT_CERTIFICATE", config.ClientCertificate},
		{"JELLYFIN_CLIENT_KEY", config.ClientKey},
		{"SKETCHYBAR_BIN", config.SketchybarExecutable},
	}
	for _, setting := range required {
		if setting.value == "" {
			return Config{}, fmt.Errorf("missing environment setting %s", setting.name)
		}
	}
	return config, nil
}

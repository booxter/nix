package repoacl

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type Config struct {
	Repository        string `json:"repository"`
	User              string `json:"user"`
	SetfaclExecutable string `json:"setfaclExecutable"`
}

func LoadConfig(path string) (Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return Config{}, fmt.Errorf("open configuration: %w", err)
	}
	defer file.Close()

	config, err := decodeConfig(file)
	if err != nil {
		return Config{}, fmt.Errorf("load configuration: %w", err)
	}
	return config, nil
}

func decodeConfig(reader io.Reader) (Config, error) {
	decoder := json.NewDecoder(reader)
	decoder.DisallowUnknownFields()
	var config Config
	if err := decoder.Decode(&config); err != nil {
		return Config{}, err
	}
	if err := config.Validate(); err != nil {
		return Config{}, err
	}
	return config, nil
}

func (config Config) Validate() error {
	if !filepath.IsAbs(config.Repository) {
		return fmt.Errorf("repository must be an absolute path")
	}
	if config.User == "" {
		return fmt.Errorf("user must not be empty")
	}
	if !filepath.IsAbs(config.SetfaclExecutable) {
		return fmt.Errorf("setfaclExecutable must be an absolute path")
	}
	return nil
}

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

type serviceConfig struct {
	URL         string
	APIKeyFile  string
	QueueURL    string
	DisableFile string
}

type config struct {
	Database        string
	MetricsFile     string
	Listen          string
	Origins         []string
	Radarr          serviceConfig
	Lidarr          serviceConfig
	TransmissionURL string
	SABnzbdURL      string
	SABnzbdKeyFile  string
	Helper          string
	Roots           map[string]string
	PlannerSocket   string
}

const (
	requestTimeout = 30 * time.Second
	mediaTimeout   = 31 * time.Minute
	plannerTimeout = 21 * time.Minute
	queueInterval  = 15 * time.Minute
)

func readConfig(path string) (config, error) {
	file, err := os.Open(path)
	if err != nil {
		return config{}, err
	}
	defer file.Close()

	var configuration config
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&configuration); err != nil {
		return config{}, fmt.Errorf("read configuration: %w", err)
	}
	return configuration, nil
}

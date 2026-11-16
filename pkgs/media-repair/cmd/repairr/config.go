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
	Timeouts        timeouts
	TraceEndpoint   string
}

const queueInterval = 15 * time.Minute

type timeouts struct {
	RequestSeconds       int
	ProbeSeconds         int
	MediaSeconds         int
	PlanningSeconds      int
	ResponseGraceSeconds int
}

func (limits timeouts) mediaRequest() time.Duration {
	return time.Duration(limits.MediaSeconds+limits.ResponseGraceSeconds) * time.Second
}

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
	limits := configuration.Timeouts
	if limits.RequestSeconds <= 0 || limits.ProbeSeconds <= 0 || limits.MediaSeconds <= 0 ||
		limits.PlanningSeconds <= 0 || limits.ResponseGraceSeconds <= 0 {
		return config{}, fmt.Errorf("all timeout settings must be positive")
	}
	return configuration, nil
}

package qos

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
)

type Config struct {
	RouteProbe    string   `json:"routeProbe"`
	Users         []string `json:"users"`
	Mark          uint32   `json:"mark"`
	OuterRateBits uint64   `json:"outerRateBits"`
	CloudRateBits uint64   `json:"cloudRateBits"`
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
	if net.ParseIP(config.RouteProbe) == nil {
		return fmt.Errorf("routeProbe must be an IP address")
	}
	if len(config.Users) == 0 {
		return fmt.Errorf("users must not be empty")
	}
	seen := make(map[string]struct{}, len(config.Users))
	for _, name := range config.Users {
		if name == "" {
			return fmt.Errorf("users must not contain an empty name")
		}
		if _, exists := seen[name]; exists {
			return fmt.Errorf("user %q is configured more than once", name)
		}
		seen[name] = struct{}{}
	}
	if config.Mark == 0 {
		return fmt.Errorf("mark must be positive")
	}
	if config.OuterRateBits == 0 {
		return fmt.Errorf("outerRateBits must be positive")
	}
	if config.CloudRateBits == 0 || config.CloudRateBits > config.OuterRateBits {
		return fmt.Errorf("cloudRateBits must be positive and cannot exceed outerRateBits")
	}
	return nil
}

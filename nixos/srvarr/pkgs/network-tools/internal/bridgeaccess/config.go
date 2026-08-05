//go:build linux

package bridgeaccess

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"strings"
)

type Config struct {
	Namespace     string     `json:"namespace"`
	SourceAddress netip.Addr `json:"sourceAddress"`
	TCPPorts      []uint16   `json:"tcpPorts"`
}

func LoadConfig(path string) (Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return Config{}, fmt.Errorf("open configuration: %w", err)
	}
	defer file.Close()

	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	var config Config
	if err := decoder.Decode(&config); err != nil {
		return Config{}, fmt.Errorf("decode configuration: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Config{}, errors.New("decode configuration: trailing JSON value")
	}
	if err := config.validate(); err != nil {
		return Config{}, err
	}
	return config, nil
}

func (config Config) validate() error {
	if strings.TrimSpace(config.Namespace) == "" || strings.Contains(config.Namespace, "/") {
		return errors.New("namespace must be a non-empty name")
	}
	if !config.SourceAddress.Is4() {
		return errors.New("sourceAddress must be an IPv4 address")
	}
	if len(config.TCPPorts) == 0 {
		return errors.New("tcpPorts must not be empty")
	}
	seen := make(map[uint16]struct{}, len(config.TCPPorts))
	for _, port := range config.TCPPorts {
		if port == 0 {
			return errors.New("tcpPorts must contain valid non-zero ports")
		}
		if _, exists := seen[port]; exists {
			return fmt.Errorf("tcpPorts contains duplicate port %d", port)
		}
		seen[port] = struct{}{}
	}
	return nil
}

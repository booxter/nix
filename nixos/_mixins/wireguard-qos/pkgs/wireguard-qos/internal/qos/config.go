package qos

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
)

type PortDirection string

const (
	SourcePort      PortDirection = "source"
	DestinationPort PortDirection = "destination"
)

type Config struct {
	Interface     string          `json:"interface"`
	RouteProbe    string          `json:"routeProbe"`
	OuterRateBits uint64          `json:"outerRateBits"`
	WireGuard     WireGuardConfig `json:"wireguard"`
	NFS           *NFSConfig      `json:"nfs"`
}

type WireGuardConfig struct {
	Port             uint16        `json:"port"`
	UploadRateBits   uint64        `json:"uploadRateBits"`
	DownloadRateBits *uint64       `json:"downloadRateBits"`
	EgressPort       PortDirection `json:"egressPort"`
	IFBInterface     string        `json:"ifbInterface"`
}

type NFSConfig struct {
	Address  string `json:"address"`
	Port     uint16 `json:"port"`
	RateBits uint64 `json:"rateBits"`
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
	if config.Interface == "" && net.ParseIP(config.RouteProbe) == nil {
		return fmt.Errorf("routeProbe must be an IP address when interface is unset")
	}
	if config.OuterRateBits == 0 {
		return fmt.Errorf("outerRateBits must be positive")
	}
	if config.WireGuard.Port == 0 {
		return fmt.Errorf("wireguard.port must be positive")
	}
	if config.WireGuard.UploadRateBits == 0 {
		return fmt.Errorf("wireguard.uploadRateBits must be positive")
	}
	if config.WireGuard.UploadRateBits > config.OuterRateBits {
		return fmt.Errorf("wireguard.uploadRateBits cannot exceed outerRateBits")
	}
	if config.WireGuard.EgressPort != SourcePort && config.WireGuard.EgressPort != DestinationPort {
		return fmt.Errorf("wireguard.egressPort must be %q or %q", SourcePort, DestinationPort)
	}
	if config.WireGuard.DownloadRateBits != nil {
		if *config.WireGuard.DownloadRateBits == 0 {
			return fmt.Errorf("wireguard.downloadRateBits must be positive")
		}
		if config.WireGuard.IFBInterface == "" {
			return fmt.Errorf("wireguard.ifbInterface is required for download shaping")
		}
	}
	if config.NFS != nil {
		if address := net.ParseIP(config.NFS.Address); address == nil || address.To4() == nil {
			return fmt.Errorf("nfs.address must be an IPv4 address")
		}
		if config.NFS.Port == 0 {
			return fmt.Errorf("nfs.port must be positive")
		}
		if config.NFS.RateBits == 0 || config.NFS.RateBits > config.OuterRateBits {
			return fmt.Errorf("nfs.rateBits must be positive and cannot exceed outerRateBits")
		}
	}
	return nil
}

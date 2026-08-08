package dashboards

import (
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"

	"github.com/grafana/grafana-foundation-sdk/go/common"
)

type DataSource struct {
	Type string `json:"type"`
	UID  string `json:"uid"`
}

func (source DataSource) reference() common.DataSourceRef {
	return common.DataSourceRef{
		Type: ptr(source.Type),
		Uid:  ptr(source.UID),
	}
}

type DataSources struct {
	Prometheus DataSource `json:"prometheus"`
}

type Config struct {
	DataSources DataSources `json:"dataSources"`
	Hosts       []Host      `json:"hosts"`
	Network     Network     `json:"network"`
}

type Network struct {
	Internet InternetLink `json:"internet"`
}

type InternetLink struct {
	Ingress LinkDirection `json:"ingress"`
	Egress  LinkDirection `json:"egress"`
}

type LinkDirection struct {
	CapacityMbit float64 `json:"capacityMbit"`
	TargetMbit   float64 `json:"targetMbit"`
}

type HostStorage struct {
	Btrfs    bool `json:"btrfs"`
	DiskBays bool `json:"diskBays"`
	NVMe     bool `json:"nvme"`
}

type HostBackups struct {
	Client bool `json:"client"`
	Server bool `json:"server"`
}

type Host struct {
	Name            string      `json:"name"`
	Platform        string      `json:"platform"`
	CapacityProfile string      `json:"capacityProfile"`
	ThermalProfile  string      `json:"thermalProfile"`
	GPUVendor       *string     `json:"gpuVendor"`
	Services        []string    `json:"services"`
	Storage         HostStorage `json:"storage"`
	Backups         HostBackups `json:"backups"`
	Virtual         bool        `json:"virtual"`
	Builder         bool        `json:"builder"`
	Hypervisor      bool        `json:"hypervisor"`
}

var hostNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]*$`)

func DecodeConfig(reader io.Reader) (Config, error) {
	decoder := json.NewDecoder(reader)
	decoder.DisallowUnknownFields()

	var config Config
	if err := decoder.Decode(&config); err != nil {
		return Config{}, fmt.Errorf("decode dashboard config: %w", err)
	}
	if config.DataSources.Prometheus.Type == "" {
		return Config{}, fmt.Errorf("Prometheus datasource type is required")
	}
	if config.DataSources.Prometheus.UID == "" {
		return Config{}, fmt.Errorf("Prometheus datasource UID is required")
	}
	if len(config.Hosts) == 0 {
		return Config{}, fmt.Errorf("at least one dashboard host is required")
	}
	for direction, link := range map[string]LinkDirection{
		"ingress": config.Network.Internet.Ingress,
		"egress":  config.Network.Internet.Egress,
	} {
		if link.TargetMbit <= 0 || link.CapacityMbit <= 0 {
			return Config{}, fmt.Errorf("internet %s rates must be positive", direction)
		}
		if link.TargetMbit > link.CapacityMbit {
			return Config{}, fmt.Errorf("internet %s target exceeds capacity", direction)
		}
	}
	seenHosts := make(map[string]struct{}, len(config.Hosts))
	for _, host := range config.Hosts {
		if !hostNamePattern.MatchString(host.Name) {
			return Config{}, fmt.Errorf("host name %q is invalid", host.Name)
		}
		if _, present := seenHosts[host.Name]; present {
			return Config{}, fmt.Errorf("host name %q is duplicated", host.Name)
		}
		seenHosts[host.Name] = struct{}{}
		if host.Platform != "linux" && host.Platform != "darwin" {
			return Config{}, fmt.Errorf("host %q has invalid platform %q", host.Name, host.Platform)
		}
		if host.CapacityProfile == "" || host.ThermalProfile == "" {
			return Config{}, fmt.Errorf("host %q lacks observability profiles", host.Name)
		}
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return Config{}, fmt.Errorf("dashboard config contains multiple JSON values")
		}
		return Config{}, fmt.Errorf("decode trailing dashboard config data: %w", err)
	}

	return config, nil
}

func DecodeConfigString(contents string) (Config, error) {
	return DecodeConfig(strings.NewReader(contents))
}

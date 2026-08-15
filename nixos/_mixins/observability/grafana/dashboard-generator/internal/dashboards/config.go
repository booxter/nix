package dashboards

import (
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"slices"
	"strings"

	"github.com/grafana/grafana-foundation-sdk/go/common"
)

type DataSource struct {
	Type string `json:"type"`
	UID  string `json:"uid"`
}

func (config Config) serviceHost(service string) (string, error) {
	hosts := make([]string, 0, 1)
	for _, host := range config.Hosts {
		if slices.Contains(host.Services, service) {
			hosts = append(hosts, host.Name)
		}
	}
	if len(hosts) != 1 {
		return "", fmt.Errorf("service %q has %d dashboard hosts, want one", service, len(hosts))
	}
	return hosts[0], nil
}

func (config Config) backupServer() (string, error) {
	hosts := make([]string, 0, 1)
	for _, host := range config.Hosts {
		if host.BackupServer {
			hosts = append(hosts, host.Name)
		}
	}
	if len(hosts) != 1 {
		return "", fmt.Errorf("dashboard inventory has %d backup servers, want one", len(hosts))
	}
	return hosts[0], nil
}

func (config Config) diskBayHost() (Host, error) {
	hosts := make([]Host, 0, 1)
	for _, host := range config.Hosts {
		if host.DiskBays != nil {
			hosts = append(hosts, host)
		}
	}
	if len(hosts) != 1 {
		return Host{}, fmt.Errorf("dashboard inventory has %d disk-bay hosts, want one", len(hosts))
	}
	return hosts[0], nil
}

func (source DataSource) reference() common.DataSourceRef {
	return common.DataSourceRef{
		Type: ptr(source.Type),
		Uid:  ptr(source.UID),
	}
}

type DataSources struct {
	Prometheus DataSource `json:"prometheus"`
	Loki       DataSource `json:"loki"`
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

type DiskBayLayout struct {
	Rows    int `json:"rows"`
	Columns int `json:"columns"`
}

type Host struct {
	Name         string         `json:"name"`
	Platform     string         `json:"platform"`
	GPUVendor    *string        `json:"gpuVendor"`
	Services     []string       `json:"services"`
	DiskBays     *DiskBayLayout `json:"diskBays"`
	BackupServer bool           `json:"backupServer"`
	Virtual      bool           `json:"virtual"`
	Builder      bool           `json:"builder"`
	Hypervisor   bool           `json:"hypervisor"`
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
	if config.DataSources.Loki.Type == "" || config.DataSources.Loki.UID == "" {
		return Config{}, fmt.Errorf("Loki datasource type and UID are required")
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
		if host.DiskBays != nil {
			layout := host.DiskBays
			if layout.Rows <= 0 || layout.Columns <= 0 || 12%layout.Columns != 0 {
				return Config{}, fmt.Errorf(
					"host %q has invalid disk-bay grid %dx%d", host.Name, layout.Columns, layout.Rows,
				)
			}
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

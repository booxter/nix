package dashboards

import (
	"encoding/json"
	"fmt"
	"io"
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
}

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

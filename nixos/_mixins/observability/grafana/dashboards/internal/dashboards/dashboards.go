package dashboards

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/grafana/grafana-foundation-sdk/go/dashboard"
)

type Definition struct {
	Path      string
	Dashboard dashboard.Dashboard
}

type FileWriter interface {
	MkdirAll(path string, perm fs.FileMode) error
	WriteFile(name string, data []byte, perm fs.FileMode) error
}

type OSFileWriter struct{}

func (OSFileWriter) MkdirAll(path string, perm fs.FileMode) error {
	return os.MkdirAll(path, perm)
}

func (OSFileWriter) WriteFile(name string, data []byte, perm fs.FileMode) error {
	return os.WriteFile(name, data, perm)
}

func All(config Config) ([]Definition, error) {
	scrapeHealth, err := ScrapeHealth(config)
	if err != nil {
		return nil, fmt.Errorf("build scrape health dashboard: %w", err)
	}

	return []Definition{
		{
			Path:      "scrape-health.json",
			Dashboard: scrapeHealth,
		},
	}, nil
}

func WriteAll(writer FileWriter, config Config, output string) error {
	definitions, err := All(config)
	if err != nil {
		return err
	}

	for _, definition := range definitions {
		path := filepath.Join(output, definition.Path)
		if err := writer.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return fmt.Errorf("create dashboard directory: %w", err)
		}
		contents, err := json.MarshalIndent(definition.Dashboard, "", "  ")
		if err != nil {
			return fmt.Errorf("encode %s: %w", definition.Path, err)
		}
		contents = append(contents, '\n')
		if err := writer.WriteFile(path, contents, 0o644); err != nil {
			return fmt.Errorf("write %s: %w", definition.Path, err)
		}
	}

	return nil
}

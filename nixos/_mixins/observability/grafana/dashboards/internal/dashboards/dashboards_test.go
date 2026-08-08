package dashboards

import (
	"io/fs"
	"path/filepath"
	"testing"
)

type memoryWriter struct {
	directories []string
	files       map[string][]byte
}

var testConfig = Config{
	DataSources: DataSources{
		Prometheus: DataSource{Type: "prometheus", UID: "prometheus"},
	},
}

func (writer *memoryWriter) MkdirAll(path string, _ fs.FileMode) error {
	writer.directories = append(writer.directories, path)
	return nil
}

func (writer *memoryWriter) WriteFile(path string, contents []byte, _ fs.FileMode) error {
	writer.files[path] = contents
	return nil
}

func TestWriteAllProducesScrapeHealthDashboard(t *testing.T) {
	writer := &memoryWriter{files: make(map[string][]byte)}
	output := "/dashboards"

	if err := WriteAll(writer, testConfig, output); err != nil {
		t.Fatalf("WriteAll() error = %v", err)
	}

	path := filepath.Join(output, "Fleet", "scrape-health.json")
	contents, present := writer.files[path]
	if !present {
		t.Fatalf("WriteAll() did not write %s", path)
	}
	if len(contents) == 0 || contents[len(contents)-1] != '\n' {
		t.Fatal("generated dashboard is empty or lacks a trailing newline")
	}
}

func TestScrapeHealthIdentity(t *testing.T) {
	model, err := ScrapeHealth(testConfig)
	if err != nil {
		t.Fatalf("ScrapeHealth() error = %v", err)
	}
	if model.Uid == nil || *model.Uid != "scrape-health" {
		t.Fatalf("ScrapeHealth() UID = %v", model.Uid)
	}
	if model.Title == nil || *model.Title != "Scrape Health" {
		t.Fatalf("ScrapeHealth() title = %v", model.Title)
	}
	if len(model.Panels) != 3 {
		t.Fatalf("ScrapeHealth() panels = %d, want 3", len(model.Panels))
	}
}

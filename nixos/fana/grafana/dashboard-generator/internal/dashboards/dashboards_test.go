package dashboards

import (
	"fmt"
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
		Loki:       DataSource{Type: "loki", UID: "loki"},
	},
	Hosts: []Host{
		{
			Name: "frame", Platform: "linux",
			Builder: true, Backups: HostBackups{Server: true},
			Storage: HostStorage{DiskBays: &DiskBayLayout{Rows: 5, Columns: 3}},
			Services: []string{
				"home", "jellyfin", "lidarr", "ollama", "paperless", "paperless-gpt",
				"sabnzbd", "transmission",
			},
		},
	},
	Network: Network{Internet: InternetLink{
		Ingress: LinkDirection{CapacityMbit: 1000, TargetMbit: 400},
		Egress:  LinkDirection{CapacityMbit: 40, TargetMbit: 25},
	}},
}

func TestHostDashboardReflectsHostCapabilities(t *testing.T) {
	host := Host{
		Name: "prx1-lab", Platform: "linux",
		Hypervisor: true,
	}
	model, err := HostDashboard(testConfig, host)
	if err != nil {
		t.Fatalf("HostDashboard() error = %v", err)
	}
	if model.Uid == nil || *model.Uid != "host-prx1-lab" {
		t.Fatalf("HostDashboard() UID = %v", model.Uid)
	}
	if len(model.Panels) != 10 {
		t.Fatalf("HostDashboard() panels = %d, want 10", len(model.Panels))
	}
}

func TestStorageDashboardPreservesPhysicalBayGrid(t *testing.T) {
	model, err := StorageOverview(testConfig)
	if err != nil {
		t.Fatalf("StorageOverview() error = %v", err)
	}

	panels := make(map[string]struct{})
	for _, item := range model.Panels {
		panel := item.Panel
		if panel == nil || panel.Title == nil || panel.GridPos == nil || panel.GridPos.H != 2 {
			continue
		}
		if panel.GridPos.Y < 6 || panel.GridPos.Y > 14 {
			continue
		}
		key := fmt.Sprintf("%s:%d:%d:%d", *panel.Title, panel.GridPos.X, panel.GridPos.Y, panel.GridPos.W)
		panels[key] = struct{}{}
	}

	for column := 0; column < 3; column++ {
		for row := 0; row < 5; row++ {
			bay := column*5 + row + 1
			for _, x := range []uint32{uint32(column * 4), uint32(12 + column*4)} {
				key := fmt.Sprintf("%d:%d:%d:4", bay, x, 6+row*2)
				if _, present := panels[key]; !present {
					t.Errorf("physical bay grid lacks panel %s", key)
				}
			}
		}
	}
	if len(panels) != 30 {
		t.Errorf("physical bay grid has %d slot panels, want 30", len(panels))
	}
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

package reconcile

import (
	"encoding/xml"
	"os"
	"path/filepath"
	"testing"
)

func TestSystemdCredentialsReadXMLField(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "service-api")
	payload, err := xml.Marshal(struct {
		XMLName xml.Name `xml:"Config"`
		APIKey  string   `xml:"ApiKey"`
	}{APIKey: "secret-value"})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	value, err := (SystemdCredentials{Directory: directory}).Read(Credential{
		Name: "service-api", Format: "xml-element", Field: "ApiKey",
	})
	if err != nil {
		t.Fatal(err)
	}
	if value != "secret-value" {
		t.Fatalf("unexpected credential value %q", value)
	}
}

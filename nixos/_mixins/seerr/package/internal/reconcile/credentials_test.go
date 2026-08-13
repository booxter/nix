package reconcile

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSystemdCredentialsReadXMLField(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "service-api")
	if err := os.WriteFile(path, []byte("<Config><ApiKey>secret-value</ApiKey></Config>"), 0o600); err != nil {
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

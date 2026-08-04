package bootstrap

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type initializerFunc func(context.Context, Config) error

func (initialize initializerFunc) Initialize(ctx context.Context, config Config) error {
	return initialize(ctx, config)
}

func testConfig(directory string) Config {
	return Config{
		StateDirectory:      directory,
		Name:                "Home CA",
		URL:                 "https://pki.example.test:8443",
		DNSNames:            []string{"pki", "pki.example.test"},
		Address:             ":8443",
		Provisioner:         "bootstrap@example.test",
		CertificateLifetime: "4320h0m0s",
	}
}

func writeJSON(t *testing.T, path string, value any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	contents, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
}

func readJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(contents, &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func generatedConfig() map[string]any {
	return map[string]any{
		"dnsNames": []any{"old.example.test"},
		"root":     "preserved",
		"authority": map[string]any{
			"options": "preserved",
			"provisioners": []any{
				map[string]any{
					"name": "bootstrap@example.test",
					"claims": map[string]any{
						"enableSSHCA": true,
					},
				},
				map[string]any{"name": "acme", "type": "ACME"},
			},
		},
	}
}

func TestRunInitializesMissingCAAndReconcilesGeneratedFiles(t *testing.T) {
	directory := t.TempDir()
	config := testConfig(directory)
	calls := 0
	initializer := initializerFunc(func(_ context.Context, received Config) error {
		calls++
		writeJSON(t, received.caConfigPath(), generatedConfig())
		writeJSON(t, received.defaultsPath(), map[string]any{
			"ca-url":      "https://old.example.test",
			"fingerprint": "preserved",
		})
		return nil
	})

	if err := Run(context.Background(), config, initializer, strings.NewReader(strings.Repeat("x", 96))); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatalf("initializer called %d times, want once", calls)
	}
	for _, path := range []string{config.passwordPath(), config.provisionerPasswordPath()} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Errorf("%s mode is %o, want 600", path, info.Mode().Perm())
		}
		contents, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if len(contents) != 65 || contents[len(contents)-1] != '\n' {
			t.Errorf("%s does not contain an openssl-compatible base64 secret", path)
		}
	}

	ca := readJSON(t, config.caConfigPath())
	if ca["root"] != "preserved" {
		t.Errorf("unrelated CA configuration was not preserved: %#v", ca)
	}
	dnsNames := ca["dnsNames"].([]any)
	if strings.Join([]string{dnsNames[0].(string), dnsNames[1].(string)}, ",") != strings.Join(config.DNSNames, ",") {
		t.Errorf("dnsNames = %#v, want %#v", dnsNames, config.DNSNames)
	}
	authority := ca["authority"].(map[string]any)
	provisioner := authority["provisioners"].([]any)[0].(map[string]any)
	claims := provisioner["claims"].(map[string]any)
	if claims["defaultTLSCertDuration"] != config.CertificateLifetime || claims["maxTLSCertDuration"] != config.CertificateLifetime {
		t.Errorf("certificate lifetime claims were not reconciled: %#v", claims)
	}
	if claims["enableSSHCA"] != true || authority["options"] != "preserved" {
		t.Errorf("unrelated authority configuration was not preserved: %#v", authority)
	}

	defaults := readJSON(t, config.defaultsPath())
	if defaults["ca-url"] != config.URL || defaults["fingerprint"] != "preserved" {
		t.Errorf("defaults were not reconciled safely: %#v", defaults)
	}
}

func TestRunReconcilesExistingCAWithoutInitialization(t *testing.T) {
	directory := t.TempDir()
	config := testConfig(directory)
	writeJSON(t, config.caConfigPath(), generatedConfig())
	writeJSON(t, config.defaultsPath(), map[string]any{"ca-url": "old"})
	initializer := initializerFunc(func(context.Context, Config) error {
		t.Fatal("initializer called for an existing CA")
		return nil
	})

	if err := Run(context.Background(), config, initializer, io.LimitReader(strings.NewReader(""), 0)); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{config.passwordPath(), config.provisionerPasswordPath()} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("password path %s unexpectedly created", path)
		}
	}
}

func TestLoadConfigRejectsUnknownAndEmptyFields(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "config.json")
	if err := os.WriteFile(path, []byte(`{"stateDirectory":"/state","unknown":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(path); err == nil {
		t.Fatal("unknown field accepted")
	}

	contents, err := json.Marshal(testConfig(""))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(path); err == nil || !strings.Contains(err.Error(), "stateDirectory") {
		t.Fatalf("empty state directory error = %v", err)
	}
}

package repoacl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type recordingGranter struct {
	access   map[string]bool
	defaults map[string]bool
}

func newRecordingGranter() *recordingGranter {
	return &recordingGranter{access: map[string]bool{}, defaults: map[string]bool{}}
}

func (granter *recordingGranter) GrantAccess(_ string, paths []string) error {
	for _, path := range paths {
		granter.access[path] = true
	}
	return nil
}

func (granter *recordingGranter) GrantDefault(_ string, paths []string) error {
	for _, path := range paths {
		granter.defaults[path] = true
	}
	return nil
}

func config(repository string) Config {
	return Config{
		Repository:        repository,
		User:              "restic-org-offload",
		SetfaclExecutable: "/bin/setfacl",
	}
}

func TestMissingRepositoryDoesNothing(t *testing.T) {
	granter := newRecordingGranter()
	if err := Sync(config(filepath.Join(t.TempDir(), "missing")), granter); err != nil {
		t.Fatal(err)
	}
	if len(granter.access) != 0 || len(granter.defaults) != 0 {
		t.Fatal("missing repository received ACL changes")
	}
}

func TestUninitializedRepositoryOnlyGrantsRootAccess(t *testing.T) {
	repository := t.TempDir()
	granter := newRecordingGranter()

	if err := Sync(config(repository), granter); err != nil {
		t.Fatal(err)
	}

	if !granter.access[repository] || !granter.defaults[repository] {
		t.Fatal("repository root did not receive access and default ACLs")
	}
	if _, err := os.Stat(filepath.Join(repository, markerName)); !os.IsNotExist(err) {
		t.Fatal("uninitialized repository unexpectedly received a marker")
	}
}

func TestInitialScanGrantsEveryPathAndDirectoryDefaults(t *testing.T) {
	repository := t.TempDir()
	configPath := filepath.Join(repository, "config")
	dataDirectory := filepath.Join(repository, "data")
	dataFile := filepath.Join(dataDirectory, "pack")
	if err := os.WriteFile(configPath, []byte("restic"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(dataDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dataFile, []byte("pack"), 0o600); err != nil {
		t.Fatal(err)
	}
	granter := newRecordingGranter()

	if err := Sync(config(repository), granter); err != nil {
		t.Fatal(err)
	}

	for _, path := range []string{repository, configPath, dataDirectory, dataFile} {
		if !granter.access[path] {
			t.Errorf("%s did not receive an access ACL", path)
		}
	}
	for _, path := range []string{repository, dataDirectory} {
		if !granter.defaults[path] {
			t.Errorf("%s did not receive a default ACL", path)
		}
	}
	if _, err := os.Stat(filepath.Join(repository, markerName)); err != nil {
		t.Fatal("initial scan did not create its marker")
	}
}

func TestIncrementalScanOnlyGrantsPathsNewerThanMarker(t *testing.T) {
	repository := t.TempDir()
	configPath := filepath.Join(repository, "config")
	oldFile := filepath.Join(repository, "old-pack")
	newFile := filepath.Join(repository, "new-pack")
	marker := filepath.Join(repository, markerName)
	for _, path := range []string{configPath, oldFile, newFile, marker} {
		if err := os.WriteFile(path, []byte("data"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Unix(1_000, 0)
	cutoff := time.Unix(2_000, 0)
	newer := time.Unix(3_000, 0)
	for _, path := range []string{repository, configPath, oldFile} {
		if err := os.Chtimes(path, old, old); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chtimes(marker, cutoff, cutoff); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(newFile, newer, newer); err != nil {
		t.Fatal(err)
	}
	granter := newRecordingGranter()

	if err := Sync(config(repository), granter); err != nil {
		t.Fatal(err)
	}

	if !granter.access[newFile] {
		t.Fatal("new pack did not receive an access ACL")
	}
	if granter.access[oldFile] || granter.access[configPath] {
		t.Fatal("unchanged repository files received incremental ACL work")
	}
}

func TestConfigRejectsUnknownAndRelativeFields(t *testing.T) {
	for name, document := range map[string]string{
		"unknown":             `{"repository":"/repo","user":"offload","setfaclExecutable":"/bin/setfacl","typo":true}`,
		"relative repository": `{"repository":"repo","user":"offload","setfaclExecutable":"/bin/setfacl"}`,
		"relative executable": `{"repository":"/repo","user":"offload","setfaclExecutable":"setfacl"}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeConfig(strings.NewReader(document)); err == nil {
				t.Fatal("invalid configuration was accepted")
			}
		})
	}
}

package mediaroot

import (
	"reflect"
	"strings"
	"testing"
)

func TestMappingsParseAndCopyRoots(t *testing.T) {
	t.Parallel()

	mappings := NewMappings()
	if err := mappings.Set("root:downloads=/data/downloads"); err != nil {
		t.Fatal(err)
	}
	if err := mappings.Set("root:archive=/data/archive"); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"root:downloads": "/data/downloads",
		"root:archive":   "/data/archive",
	}
	if paths := mappings.Paths(); !reflect.DeepEqual(paths, want) {
		t.Fatalf("paths = %#v, want %#v", paths, want)
	}
	paths := mappings.Paths()
	paths["root:downloads"] = "/changed"
	if mappings["root:downloads"] != "/data/downloads" {
		t.Fatal("returned paths alias the parsed mappings")
	}
	if strings.Contains(mappings.String(), "/data") {
		t.Fatalf("String exposes configured paths: %q", mappings.String())
	}
}

func TestMappingsRejectInvalidRoots(t *testing.T) {
	t.Parallel()

	tests := []string{
		"missing-separator",
		"=/data/downloads",
		"root:downloads=",
		"root:downloads=relative",
		"root:downloads=/data/../downloads",
		"root:\x00downloads=/data/downloads",
		"root:downloads=/data/\x00downloads",
	}
	for _, value := range tests {
		mappings := NewMappings()
		if err := mappings.Set(value); err == nil {
			t.Fatalf("mapping %q was accepted", value)
		}
	}

	mappings := NewMappings()
	if err := mappings.Set("root:downloads=/data/downloads"); err != nil {
		t.Fatal(err)
	}
	if err := mappings.Set("root:downloads=/other"); err == nil {
		t.Fatal("duplicate root ID was accepted")
	}
}

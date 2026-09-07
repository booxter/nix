package workercontracts

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func readFixture(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestProbeRequestExampleDecodesAndRoundTrips(t *testing.T) {
	t.Parallel()

	request, err := DecodeProbeRequest(readFixture(t, "v1/examples/probe-request.json"))
	if err != nil {
		t.Fatal(err)
	}
	if string(request.SchemaVersion) != "radarr-repair-worker/v1" ||
		string(request.Operation) != "probe_v1" || request.RequestID != "request:01" ||
		request.RootID != "root:downloads" ||
		!reflect.DeepEqual(request.PathComponents, []string{
			"Example.Movie.2024.1080p.BluRay-GROUP",
			"Example.Movie.2024.CD1.mkv",
		}) {
		t.Fatalf("request = %#v", request)
	}

	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeProbeRequest(encoded); err != nil {
		t.Fatalf("decode round trip: %v", err)
	}
}

func TestInvalidProbeRequestFixturesAreRejected(t *testing.T) {
	t.Parallel()

	paths, err := filepath.Glob("../contract-tests/v1/request-*.json")
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) == 0 {
		t.Fatal("no negative probe request fixtures found")
	}
	for _, path := range paths {
		path := path
		t.Run(filepath.Base(path), func(t *testing.T) {
			t.Parallel()
			if _, err := DecodeProbeRequest(readFixture(t, path)); err == nil {
				t.Fatal("invalid probe request was accepted")
			}
		})
	}
}

func TestDecodeProbeRequestRejectsTrailingJSON(t *testing.T) {
	t.Parallel()

	data := append(readFixture(t, "v1/examples/probe-request.json"), []byte("\n{}")...)
	if _, err := DecodeProbeRequest(data); err == nil {
		t.Fatal("probe request with trailing JSON was accepted")
	}
}

func TestDecodeProbeRequestRejectsOversizedDocument(t *testing.T) {
	t.Parallel()

	if _, err := DecodeProbeRequest(make([]byte, MaxProbeRequestBytes+1)); err == nil {
		t.Fatal("oversized probe request was accepted")
	}
}

package workercontracts

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

func TestProbeResponseExamplesDecodeAndRoundTrip(t *testing.T) {
	t.Parallel()

	tests := []struct {
		path string
		kind ProbeResponseKind
	}{
		{path: "v1/examples/probe-response-ok.json", kind: ProbeResponseSucceeded},
		{path: "v1/examples/probe-response-failed.json", kind: ProbeResponseFailed},
	}
	for _, test := range tests {
		t.Run(string(test.kind), func(t *testing.T) {
			t.Parallel()
			response, err := DecodeProbeResponse(readFixture(t, test.path))
			if err != nil {
				t.Fatal(err)
			}
			if response.Kind != test.kind || response.RequestID() != "request:01" ||
				(response.Success == nil) == (response.Failure == nil) {
				t.Fatalf("response = %#v", response)
			}
			if response.Success != nil {
				streams := response.Success.Evidence.Streams
				if len(streams) != 1 || streams[0].CodecName == nil ||
					*streams[0].CodecName != "h264" {
					t.Fatalf("evidence = %#v", response.Success.Evidence)
				}
			}

			var encoded []byte
			if response.Success != nil {
				encoded, err = json.Marshal(response.Success)
			} else {
				encoded, err = json.Marshal(response.Failure)
			}
			if err != nil {
				t.Fatal(err)
			}
			if _, err := DecodeProbeResponse(encoded); err != nil {
				t.Fatalf("decode round trip: %v", err)
			}
		})
	}
}

func TestProbeResponseAcceptsClosedFailureReasons(t *testing.T) {
	t.Parallel()

	reasons := []string{
		"unknown_root",
		"invalid_path",
		"file_unavailable",
		"not_regular_file",
		"fingerprint_mismatch",
		"unsupported_format",
		"timeout",
		"probe_error",
		"invalid_output",
		"internal_error",
	}
	fixture := string(readFixture(t, "v1/examples/probe-response-failed.json"))
	for _, reason := range reasons {
		t.Run(reason, func(t *testing.T) {
			t.Parallel()
			data := strings.Replace(fixture, "fingerprint_mismatch", reason, 1)
			response, err := DecodeProbeResponse([]byte(data))
			if err != nil {
				t.Fatal(err)
			}
			if response.Failure == nil || string(response.Failure.Reason) != reason {
				t.Fatalf("response = %#v", response)
			}
		})
	}
}

func TestInvalidProbeResponseFixturesAreRejected(t *testing.T) {
	t.Parallel()

	paths, err := filepath.Glob("../contract-tests/v1/response-*.json")
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) == 0 {
		t.Fatal("no negative probe response fixtures found")
	}
	for _, path := range paths {
		path := path
		t.Run(filepath.Base(path), func(t *testing.T) {
			t.Parallel()
			if _, err := DecodeProbeResponse(readFixture(t, path)); err == nil {
				t.Fatal("invalid probe response was accepted")
			}
		})
	}
}

func TestDecodeProbeResponseRejectsTrailingJSON(t *testing.T) {
	t.Parallel()

	data := append(readFixture(t, "v1/examples/probe-response-failed.json"), []byte("\n{}")...)
	if _, err := DecodeProbeResponse(data); err == nil {
		t.Fatal("probe response with trailing JSON was accepted")
	}
}

func TestDecodeProbeResponseRejectsOversizedDocument(t *testing.T) {
	t.Parallel()

	if _, err := DecodeProbeResponse(make([]byte, MaxProbeResponseBytes+1)); err == nil {
		t.Fatal("oversized probe response was accepted")
	}
}

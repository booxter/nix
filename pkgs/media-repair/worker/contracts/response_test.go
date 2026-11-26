package workercontracts

import (
	"path/filepath"
	"reflect"
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

			encoded, err := EncodeProbeResponse(response)
			if err != nil {
				t.Fatal(err)
			}
			decoded, err := DecodeProbeResponse(encoded)
			if err != nil {
				t.Fatalf("decode round trip: %v", err)
			}
			if !reflect.DeepEqual(decoded, response) {
				t.Fatalf("round trip = %#v, want %#v", decoded, response)
			}
		})
	}
}

func TestEncodeProbeResponseRejectsInvalidEnvelope(t *testing.T) {
	t.Parallel()

	successResponse, err := DecodeProbeResponse(
		readFixture(t, "v1/examples/probe-response-ok.json"),
	)
	if err != nil {
		t.Fatal(err)
	}
	failureResponse, err := DecodeProbeResponse(
		readFixture(t, "v1/examples/probe-response-failed.json"),
	)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name     string
		response ProbeResponseV1
	}{
		{name: "unknown kind"},
		{name: "missing success", response: ProbeResponseV1{Kind: ProbeResponseSucceeded}},
		{
			name: "success with failure",
			response: ProbeResponseV1{
				Kind:    ProbeResponseSucceeded,
				Success: successResponse.Success,
				Failure: failureResponse.Failure,
			},
		},
		{name: "missing failure", response: ProbeResponseV1{Kind: ProbeResponseFailed}},
		{
			name: "failure with success",
			response: ProbeResponseV1{
				Kind:    ProbeResponseFailed,
				Success: successResponse.Success,
				Failure: failureResponse.Failure,
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if _, err := EncodeProbeResponse(test.response); err == nil {
				t.Fatal("invalid response envelope was encoded")
			}
		})
	}
}

func TestEncodeProbeResponseValidatesGeneratedModel(t *testing.T) {
	t.Parallel()

	response, err := DecodeProbeResponse(
		readFixture(t, "v1/examples/probe-response-failed.json"),
	)
	if err != nil {
		t.Fatal(err)
	}
	response.Failure.Reason = Reason("not-a-contract-reason")
	if _, err := EncodeProbeResponse(response); err == nil {
		t.Fatal("schema-invalid generated model was encoded")
	}
}

func TestEncodeProbeResponseRejectsOversizedModel(t *testing.T) {
	t.Parallel()

	response, err := DecodeProbeResponse(
		readFixture(t, "v1/examples/probe-response-ok.json"),
	)
	if err != nil {
		t.Fatal(err)
	}
	chapter := ChapterElement{Tags: []TagElement{}}
	response.Success.Evidence.Chapters = []ChapterElement{chapter}
	if _, err := EncodeProbeResponse(response); err != nil {
		t.Fatalf("valid chapter rejected: %v", err)
	}
	response.Success.Evidence.Chapters = make([]ChapterElement, 50_000)
	for index := range response.Success.Evidence.Chapters {
		response.Success.Evidence.Chapters[index] = chapter
	}
	if _, err := EncodeProbeResponse(response); err == nil || !strings.Contains(err.Error(), "limit is") {
		t.Fatalf("oversized generated model error = %v", err)
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

func TestProbeResponseSchemaRejectsValuesOutsideInt64(t *testing.T) {
	t.Parallel()

	fixture := string(readFixture(t, "v1/examples/probe-response-ok.json"))
	for _, value := range []string{
		"9223372036854775808",
		"-9223372036854775809",
	} {
		t.Run(value, func(t *testing.T) {
			t.Parallel()
			data := strings.Replace(
				fixture,
				`"start_time_ms": 0`,
				`"start_time_ms": `+value,
				1,
			)
			if err := validateMessage(
				[]byte(data),
				MaxProbeResponseBytes,
				"probe response",
				probeResponseSchema,
			); err == nil {
				t.Fatal("probe response outside int64 bounds was accepted")
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

	valid := readFixture(t, "v1/examples/probe-response-failed.json")
	data := append(valid, []byte(strings.Repeat(" ", MaxProbeResponseBytes-len(valid)))...)
	if _, err := DecodeProbeResponse(data); err != nil {
		t.Fatalf("probe response at byte limit rejected: %v", err)
	}
	if _, err := DecodeProbeResponse(append(data, ' ')); err == nil || !strings.Contains(err.Error(), "limit is") {
		t.Fatalf("oversized probe response error = %v", err)
	}
}

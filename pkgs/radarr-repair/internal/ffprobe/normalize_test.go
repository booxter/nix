package ffprobe

import (
	"reflect"
	"strings"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

func TestNormalizeConvertsProbeEvidence(t *testing.T) {
	t.Parallel()

	document, err := Decode(readProbeFixture(t))
	if err != nil {
		t.Fatal(err)
	}
	evidence, err := Normalize(document)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(evidence.Format.Names, []string{"mpegts"}) {
		t.Fatalf("format names = %v", evidence.Format.Names)
	}
	assertInt64Pointer(t, "format start", evidence.Format.StartTimeMS, 1400)
	assertInt64Pointer(t, "format duration", evidence.Format.DurationMS, 1_800_000)
	assertInt64Pointer(t, "format size", evidence.Format.SizeBytes, 1_200_000_000)
	if len(evidence.Streams) != 2 || evidence.Streams[0].Kind == nil ||
		*evidence.Streams[0].Kind != controller.ProbeStreamVideo {
		t.Fatalf("streams = %#v", evidence.Streams)
	}
	wantFrameRate := &controller.Rational{Numerator: 24000, Denominator: 1001}
	if !reflect.DeepEqual(evidence.Streams[0].FrameRate, wantFrameRate) {
		t.Fatalf("frame rate = %#v", evidence.Streams[0].FrameRate)
	}
	assertInt64Pointer(t, "sample rate", evidence.Streams[1].SampleRateHz, 48000)
	if evidence.Streams[0].Disposition == nil || evidence.Streams[0].Disposition.Default == nil ||
		!*evidence.Streams[0].Disposition.Default {
		t.Fatalf("video disposition = %#v", evidence.Streams[0].Disposition)
	}
	if len(evidence.Programs) != 1 ||
		!reflect.DeepEqual(evidence.Programs[0].StreamIndexes, []int64{0, 1}) {
		t.Fatalf("programs = %#v", evidence.Programs)
	}
	if len(evidence.Chapters) != 1 {
		t.Fatalf("chapters = %#v", evidence.Chapters)
	}
	assertInt64Pointer(t, "chapter end", evidence.Chapters[0].EndTimeMS, 900_000)
	wantTags := []controller.ProbeTag{
		{Name: "service_name", Value: "Example Movie"},
		{Name: "service_provider", Value: "Example Provider"},
	}
	if !reflect.DeepEqual(evidence.Programs[0].Tags, wantTags) {
		t.Fatalf("program tags = %#v", evidence.Programs[0].Tags)
	}
}

func TestNormalizePreservesMissingValues(t *testing.T) {
	t.Parallel()

	document, err := Decode([]byte(`{"streams":[{"index":0}],"format":{}}`))
	if err != nil {
		t.Fatal(err)
	}
	evidence, err := Normalize(document)
	if err != nil {
		t.Fatal(err)
	}
	if evidence.Format.Names != nil || evidence.Format.DurationMS != nil ||
		len(evidence.Streams) != 1 || evidence.Streams[0].Kind != nil ||
		evidence.Streams[0].TimeBase != nil || evidence.Streams[0].Disposition != nil {
		t.Fatalf("evidence = %#v", evidence)
	}
}

func TestNormalizeSplitsFormatNames(t *testing.T) {
	t.Parallel()

	document, err := Decode([]byte(`{"streams":[],"format":{"format_name":"matroska,webm"}}`))
	if err != nil {
		t.Fatal(err)
	}
	evidence, err := Normalize(document)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(evidence.Format.Names, []string{"matroska", "webm"}) {
		t.Fatalf("format names = %v", evidence.Format.Names)
	}
}

func TestParseOptionalMilliseconds(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name          string
		value         string
		allowNegative bool
		want          *int64
		wantError     bool
	}{
		{name: "below half", value: "1.2344", want: int64Pointer(1234)},
		{name: "positive half", value: "1.2345", want: int64Pointer(1235)},
		{name: "negative half", value: "-0.0005", allowNegative: true, want: int64Pointer(-1)},
		{name: "unavailable", value: "N/A", want: nil},
		{name: "negative duration", value: "-0.001", wantError: true},
		{name: "fraction syntax", value: "1/2", wantError: true},
		{name: "overflow", value: "9223372036854775.808", wantError: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := parseOptionalMilliseconds("value", &test.value, test.allowNegative)
			if (err != nil) != test.wantError {
				t.Fatalf("value = %#v, error = %v", got, err)
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("value = %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestParseOptionalRational(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		value     string
		want      *controller.Rational
		wantError bool
	}{
		{
			name:  "reduced",
			value: "48000/2002",
			want:  &controller.Rational{Numerator: 24000, Denominator: 1001},
		},
		{
			name:  "normalized signs",
			value: "-1/-1000",
			want:  &controller.Rational{Numerator: 1, Denominator: 1000},
		},
		{name: "unavailable", value: "N/A"},
		{name: "zero over zero", value: "0/0"},
		{name: "zero denominator", value: "1/0", wantError: true},
		{name: "decimal", value: "23.976", wantError: true},
		{name: "overflow", value: "9223372036854775808/1", wantError: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := parseOptionalRational("value", &test.value)
			if (err != nil) != test.wantError {
				t.Fatalf("value = %#v, error = %v", got, err)
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("value = %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestNormalizeRejectsInvalidSemanticValues(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*Document)
		want   string
	}{
		{
			name: "negative size",
			mutate: func(document *Document) {
				document.Format.Size = stringPointer("-1")
			},
			want: "invalid size",
		},
		{
			name: "zero width",
			mutate: func(document *Document) {
				document.Streams[0].Width = int64Pointer(0)
			},
			want: "invalid width",
		},
		{
			name: "invalid disposition",
			mutate: func(document *Document) {
				document.Streams[0].Disposition.Forced = int64Pointer(2)
			},
			want: "invalid forced disposition",
		},
		{
			name: "empty stream kind",
			mutate: func(document *Document) {
				document.Streams[0].CodecType = stringPointer("")
			},
			want: "invalid stream kind",
		},
		{
			name: "control in tag",
			mutate: func(document *Document) {
				document.Format.Tags.Title = stringPointer("bad\nvalue")
			},
			want: "control characters",
		},
		{
			name: "oversized tag",
			mutate: func(document *Document) {
				document.Format.Tags.Title = stringPointer(strings.Repeat("x", maxTagValueRunes+1))
			},
			want: "exceeds 512 characters",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			document, err := Decode(readProbeFixture(t))
			if err != nil {
				t.Fatal(err)
			}
			test.mutate(&document)
			_, err = Normalize(document)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func assertInt64Pointer(t *testing.T, name string, value *int64, want int64) {
	t.Helper()
	if value == nil || *value != want {
		t.Fatalf("%s = %#v, want %d", name, value, want)
	}
}

func stringPointer(value string) *string {
	return &value
}

func int64Pointer(value int64) *int64 {
	return &value
}

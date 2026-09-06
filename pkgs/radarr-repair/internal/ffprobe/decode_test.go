package ffprobe

import (
	"os"
	"strings"
	"testing"
)

func TestDecodePreservesTypedFFprobeFields(t *testing.T) {
	t.Parallel()

	document, err := Decode(readProbeFixture(t))
	if err != nil {
		t.Fatal(err)
	}
	if document.Format == nil || document.Format.Name == nil || *document.Format.Name != "mpegts" {
		t.Fatalf("format = %#v", document.Format)
	}
	if document.Format.Duration == nil || *document.Format.Duration != "1800.000000" {
		t.Fatalf("format duration = %#v", document.Format.Duration)
	}
	if len(document.Streams) != 2 || document.Streams[0].Index == nil ||
		*document.Streams[0].Index != 0 || document.Streams[1].Index == nil ||
		*document.Streams[1].Index != 1 {
		t.Fatalf("streams = %#v", document.Streams)
	}
	if document.Streams[0].FrameRate == nil || *document.Streams[0].FrameRate != "24000/1001" {
		t.Fatalf("video frame rate = %#v", document.Streams[0].FrameRate)
	}
	if document.Streams[1].ChannelLayout == nil || *document.Streams[1].ChannelLayout != "5.1(side)" {
		t.Fatalf("audio channel layout = %#v", document.Streams[1].ChannelLayout)
	}
	if len(document.Programs) != 1 || len(document.Programs[0].Streams) != 2 ||
		document.Programs[0].Streams[1].Index == nil ||
		*document.Programs[0].Streams[1].Index != 1 {
		t.Fatalf("programs = %#v", document.Programs)
	}
	if len(document.Chapters) != 1 || document.Chapters[0].Tags == nil ||
		document.Chapters[0].Tags.Title == nil ||
		*document.Chapters[0].Tags.Title != "First half" {
		t.Fatalf("chapters = %#v", document.Chapters)
	}
}

func TestDecodePreservesMissingOptionalFields(t *testing.T) {
	t.Parallel()

	document, err := Decode([]byte(`{"streams":[{"index":0}],"format":{}}`))
	if err != nil {
		t.Fatal(err)
	}
	if document.Format == nil || document.Format.Duration != nil ||
		len(document.Streams) != 1 || document.Streams[0].CodecName != nil ||
		document.Programs != nil || document.Chapters != nil {
		t.Fatalf("document = %#v", document)
	}
}

func TestDecodeRejectsMalformedDocuments(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		data string
		want string
	}{
		{
			name: "unknown field",
			data: `{"streams":[{"index":0,"future_field":true}],"format":{}}`,
			want: "unknown field",
		},
		{
			name: "wrong field type",
			data: `{"streams":[{"index":"0"}],"format":{}}`,
			want: "cannot unmarshal string",
		},
		{
			name: "trailing value",
			data: `{"streams":[],"format":{}} {}`,
			want: "multiple JSON values",
		},
		{
			name: "missing format",
			data: `{"streams":[]}`,
			want: "missing format",
		},
		{
			name: "duplicate stream index",
			data: `{"streams":[{"index":0},{"index":0}],"format":{}}`,
			want: "duplicate stream index 0",
		},
		{
			name: "unknown program stream",
			data: `{"programs":[{"program_id":1,"streams":[{"index":2}]}],"streams":[{"index":0}],"format":{}}`,
			want: "program 1 references unknown stream index 2",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			_, err := Decode([]byte(test.data))
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestDecodeRejectsOversizedDocument(t *testing.T) {
	t.Parallel()

	_, err := Decode(make([]byte, MaxDocumentBytes+1))
	if err == nil || !strings.Contains(err.Error(), "limit") {
		t.Fatalf("error = %v", err)
	}
}

func readProbeFixture(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile("testdata/probe.json")
	if err != nil {
		t.Fatal(err)
	}
	return data
}

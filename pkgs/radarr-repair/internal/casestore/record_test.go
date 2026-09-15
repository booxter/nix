package casestore

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

const (
	recordTestDownloadID = "abcdef0123456789abcdef0123456789abcdef01"
	recordTestFileID     = controller.FileID("file:1111111111111111111111111111111111111111111111111111111111111111")
)

func TestCaseRecordRoundTrip(t *testing.T) {
	t.Parallel()

	assembly := recordTestAssembly(t)
	record, err := NewRecord(assembly)
	if err != nil {
		t.Fatal(err)
	}
	data, err := EncodeRecord(record)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeRecord(data)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(decoded, record) {
		t.Fatalf("decoded record differs:\n got: %#v\nwant: %#v", decoded, record)
	}
	if !bytes.Contains(data, []byte(`"request":{"capabilities"`)) {
		t.Fatalf("repair case was not embedded as JSON: %s", data)
	}
}

func TestNewRecordRejectsInconsistentAssembly(t *testing.T) {
	t.Parallel()

	assembly := recordTestAssembly(t)
	assembly.EncodedRequest = append(assembly.EncodedRequest, ' ')
	if _, err := NewRecord(assembly); err == nil ||
		!strings.Contains(err.Error(), "bytes do not match") {
		t.Fatalf("error = %v", err)
	}
}

func TestEncodeRecordRejectsNoncanonicalRequest(t *testing.T) {
	t.Parallel()

	record := newRecordForTest(t)
	record.Request = append(record.Request, ' ')
	if _, err := EncodeRecord(record); err == nil ||
		!strings.Contains(err.Error(), "not in canonical encoded form") {
		t.Fatalf("error = %v", err)
	}
}

func TestDecodeRecordRejectsInvalidEnvelope(t *testing.T) {
	t.Parallel()

	record := newRecordForTest(t)
	tests := []struct {
		name   string
		mutate func(*CaseRecord)
		want   string
	}{
		{
			name: "unsupported version",
			mutate: func(record *CaseRecord) {
				record.Version = "radarr-repair-state/v3"
			},
			want: "unsupported case record version",
		},
		{
			name: "record case ID mismatch",
			mutate: func(record *CaseRecord) {
				record.CaseID = "sha256:" + strings.Repeat("0", 64)
			},
			want: "record case ID does not match",
		},
		{
			name: "snapshot case ID mismatch",
			mutate: func(record *CaseRecord) {
				record.Snapshot.CaseID = "sha256:" + strings.Repeat("0", 64)
			},
			want: "snapshot case ID does not match",
		},
		{
			name: "observation changed",
			mutate: func(record *CaseRecord) {
				record.Snapshot.Observation.Correlation.Radarr.Title += " changed"
			},
			want: "does not reproduce",
		},
		{
			name: "binding removed",
			mutate: func(record *CaseRecord) {
				record.Snapshot.ManualImportBindings = map[string]controller.RadarrManualImportBinding{}
			},
			want: "bindings do not match",
		},
		{
			name: "binding changed",
			mutate: func(record *CaseRecord) {
				for capabilityID, binding := range record.Snapshot.ManualImportBindings {
					binding.File.Path += ".changed"
					record.Snapshot.ManualImportBindings[capabilityID] = binding
				}
			},
			want: "bindings do not match",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			changed := cloneRecord(t, record)
			test.mutate(&changed)
			data, err := json.Marshal(changed)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := DecodeRecord(data); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestDecodeRecordRejectsUnknownAndTrailingJSON(t *testing.T) {
	t.Parallel()

	record := newRecordForTest(t)
	data, err := EncodeRecord(record)
	if err != nil {
		t.Fatal(err)
	}
	withUnknown := append(cloneBytes(data[:len(data)-1]), []byte(`,"unknown":true}`)...)
	if _, err := DecodeRecord(withUnknown); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("unknown-field error = %v", err)
	}
	withTrailing := append(cloneBytes(data), []byte(` {}`)...)
	if _, err := DecodeRecord(withTrailing); err == nil || !strings.Contains(err.Error(), "multiple JSON values") {
		t.Fatalf("trailing-value error = %v", err)
	}
}

func newRecordForTest(t *testing.T) CaseRecord {
	t.Helper()
	record, err := NewRecord(recordTestAssembly(t))
	if err != nil {
		t.Fatal(err)
	}
	return record
}

func cloneRecord(t *testing.T, record CaseRecord) CaseRecord {
	t.Helper()
	data, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	var cloned CaseRecord
	if err := json.Unmarshal(data, &cloned); err != nil {
		t.Fatal(err)
	}
	return cloned
}

func recordTestAssembly(t *testing.T) casebuilder.Assembly {
	t.Helper()
	movieID := int64(42)
	file := controller.InventoryFile{
		ID:             recordTestFileID,
		PathComponents: []string{"PoorlyNamed.mkv"},
		Fingerprint: controller.FileFingerprint{
			Device: 1, Inode: 2, SizeBytes: 100, MTimeNS: 3,
		},
		DownloadFile: &controller.DownloadFileReference{
			Index: 0, LengthBytes: 100, BytesCompleted: 100, Selected: true,
		},
	}
	path := "/downloads/PoorlyNamed.mkv"
	observation := casebuilder.Observation{
		ObservedAt: time.Date(2026, time.September, 7, 18, 0, 0, 0, time.UTC),
		Correlation: controller.DownloadCorrelation{
			DownloadRoot: "/downloads/PoorlyNamed.mkv",
			Radarr: controller.RadarrQueueRecord{
				ID: 71, MovieID: &movieID, Title: "Poorly Named Feature",
				Status: "completed", TrackedDownloadStatus: "warning",
				TrackedDownloadState: "importPending", DownloadID: recordTestDownloadID,
				OutputPath: path,
			},
			Download: controller.Download{
				Client: controller.DownloadClientTransmission, SourceType: controller.DownloadSourceTorrent,
				ID: recordTestDownloadID, IDComparison: controller.DownloadIDASCIIInsensitive,
				Name: "Poorly Named Feature", Stable: true, Complete: true,
				OutputPath: path, TotalSizeBytes: 100,
				ContentOwnership: controller.DownloadContentManifest,
				Files: []controller.DownloadFile{{
					Index: 0, HasIndex: true, Path: path, LengthBytes: 100,
					BytesCompleted: 100, Selected: true,
				}},
				Labels: []string{},
			},
		},
		History: []controller.RadarrHistoryEvent{},
		ManualImports: []controller.RadarrManualImport{{
			Path: path, RelativePath: "PoorlyNamed.mkv", FolderName: "Poorly Named Feature",
			SizeBytes: 100, MovieID: movieID, DownloadID: recordTestDownloadID,
			Quality: &controller.RadarrQualityModel{
				Quality: controller.RadarrQuality{ID: 7, Name: "Bluray-1080p"},
			},
			Languages:  []controller.RadarrLanguage{},
			Rejections: []controller.RadarrManualImportRejection{},
		}},
		Inventory: controller.FileInventory{
			Files: []controller.InventoryFile{file},
			Paths: []controller.FilePathMapping{{FileID: file.ID, AbsolutePath: path}},
		},
		Probes: []casebuilder.FileProbe{{
			FileID: file.ID,
			Outcome: controller.FailedMediaProbe(
				controller.MediaProbeUnsupportedFormat,
			),
		}},
	}
	assembly, err := casebuilder.Assemble(observation)
	if err != nil {
		t.Fatal(err)
	}
	return assembly
}

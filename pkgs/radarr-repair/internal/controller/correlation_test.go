package controller

import (
	"reflect"
	"testing"
)

const (
	correlationIDUpper = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
	correlationIDLower = "abcdef0123456789abcdef0123456789abcdef01"
)

func TestCorrelateDownloadAcceptsStableCompletedDownload(t *testing.T) {
	t.Parallel()

	record, download := correlatedDownloadObservations()
	download.Files = append(download.Files, DownloadFile{
		Index: 2, HasIndex: true, Path: "/downloads/Example_Movie/optional.txt",
		LengthBytes: 100, Selected: false,
	})

	correlation := CorrelateDownload(record, download)
	if !correlation.Eligible() {
		t.Fatalf("rejection reasons = %v", correlation.RejectionReasons)
	}
	if correlation.DownloadRoot != "/downloads/Example_Movie" {
		t.Fatalf("download root = %q", correlation.DownloadRoot)
	}
	if !reflect.DeepEqual(correlation.Radarr, record) ||
		!reflect.DeepEqual(correlation.Download, download) {
		t.Fatal("correlation changed its observations")
	}
}

func TestCorrelateDownloadChecksClientIdentityRule(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		radarrID    string
		downloadID  string
		comparison  DownloadIDComparison
		wantReasons []CorrelationRejectionReason
	}{
		{
			name: "missing Radarr ID", downloadID: correlationIDLower,
			comparison:  DownloadIDASCIIInsensitive,
			wantReasons: []CorrelationRejectionReason{CorrelationInvalidRadarrDownloadID},
		},
		{
			name: "missing download ID", radarrID: correlationIDUpper,
			comparison:  DownloadIDASCIIInsensitive,
			wantReasons: []CorrelationRejectionReason{CorrelationInvalidDownloadID},
		},
		{
			name: "unknown comparison", radarrID: correlationIDUpper,
			downloadID:  correlationIDLower,
			wantReasons: []CorrelationRejectionReason{CorrelationInvalidDownloadID},
		},
		{
			name: "different IDs", radarrID: correlationIDUpper,
			downloadID:  "abcdef0123456789abcdef0123456789abcdef02",
			comparison:  DownloadIDASCIIInsensitive,
			wantReasons: []CorrelationRejectionReason{CorrelationDownloadIDMismatch},
		},
		{
			name: "exact comparison rejects different case", radarrID: correlationIDUpper,
			downloadID: correlationIDLower, comparison: DownloadIDExact,
			wantReasons: []CorrelationRejectionReason{CorrelationDownloadIDMismatch},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			record, download := correlatedDownloadObservations()
			record.DownloadID = test.radarrID
			download.ID = test.downloadID
			download.IDComparison = test.comparison
			correlation := CorrelateDownload(record, download)
			if !reflect.DeepEqual(correlation.RejectionReasons, test.wantReasons) {
				t.Fatalf("rejection reasons = %v, want %v", correlation.RejectionReasons, test.wantReasons)
			}
		})
	}
}

func TestCorrelateDownloadRejectsUnstableOrIncompleteDownload(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*Download)
		want   []CorrelationRejectionReason
	}{
		{
			name: "unstable", mutate: func(download *Download) { download.Stable = false },
			want: []CorrelationRejectionReason{CorrelationUnstableDownload},
		},
		{
			name: "incomplete", mutate: func(download *Download) { download.Complete = false },
			want: []CorrelationRejectionReason{CorrelationIncompleteDownload},
		},
		{
			name:   "selected file incomplete",
			mutate: func(download *Download) { download.Files[0].BytesCompleted-- },
			want:   []CorrelationRejectionReason{CorrelationIncompleteDownload},
		},
		{
			name: "no selected files",
			mutate: func(download *Download) {
				for index := range download.Files {
					download.Files[index].Selected = false
				}
			},
			want: []CorrelationRejectionReason{CorrelationNoSelectedFiles},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			record, download := correlatedDownloadObservations()
			test.mutate(&download)
			correlation := CorrelateDownload(record, download)
			if !reflect.DeepEqual(correlation.RejectionReasons, test.want) {
				t.Fatalf("rejection reasons = %v, want %v", correlation.RejectionReasons, test.want)
			}
		})
	}
}

func TestCorrelateDownloadRequiresExactSafeRoot(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*RadarrQueueRecord, *Download)
		want   CorrelationRejectionReason
	}{
		{
			name:   "relative client root",
			mutate: func(_ *RadarrQueueRecord, download *Download) { download.OutputPath = "downloads" },
			want:   CorrelationInvalidDownloadRoot,
		},
		{
			name: "unclean client root",
			mutate: func(_ *RadarrQueueRecord, download *Download) {
				download.OutputPath = "/downloads/../downloads"
			},
			want: CorrelationInvalidDownloadRoot,
		},
		{
			name: "invalid Radarr root",
			mutate: func(record *RadarrQueueRecord, _ *Download) {
				record.OutputPath = "/downloads/../Example_Movie"
			},
			want: CorrelationInvalidDownloadRoot,
		},
		{
			name: "different roots",
			mutate: func(record *RadarrQueueRecord, _ *Download) {
				record.OutputPath = "/downloads/Other.Movie"
			},
			want: CorrelationDownloadRootMismatch,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			record, download := correlatedDownloadObservations()
			test.mutate(&record, &download)
			correlation := CorrelateDownload(record, download)
			if !reflect.DeepEqual(correlation.RejectionReasons, []CorrelationRejectionReason{test.want}) {
				t.Fatalf("rejection reasons = %v, want %v", correlation.RejectionReasons, test.want)
			}
			if correlation.DownloadRoot != "" {
				t.Fatalf("download root = %q", correlation.DownloadRoot)
			}
		})
	}
}

func correlatedDownloadObservations() (RadarrQueueRecord, Download) {
	record := eligibleCandidateRecord()
	record.DownloadID = correlationIDUpper
	record.OutputPath = "/downloads/Example_Movie"
	download := Download{
		Client: DownloadClientTransmission, SourceType: DownloadSourceTorrent,
		ID: correlationIDLower, IDComparison: DownloadIDASCIIInsensitive,
		Name: "Example:Movie", Stable: true, Complete: true,
		OutputPath: "/downloads/Example_Movie", ContentOwnership: DownloadContentManifest,
		Files: []DownloadFile{
			{Index: 0, HasIndex: true, Path: "/downloads/Example_Movie/CD1.mkv", LengthBytes: 100, BytesCompleted: 100, Selected: true},
			{Index: 1, HasIndex: true, Path: "/downloads/Example_Movie/CD2.mkv", LengthBytes: 200, BytesCompleted: 200, Selected: true},
		},
	}
	return record, download
}

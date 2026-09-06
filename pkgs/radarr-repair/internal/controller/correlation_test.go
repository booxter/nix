package controller

import (
	"reflect"
	"strconv"
	"testing"
)

const (
	correlationHashUpper = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
	correlationHashLower = "abcdef0123456789abcdef0123456789abcdef01"
)

func TestCorrelateDownloadAcceptsStableCompletedTorrent(t *testing.T) {
	t.Parallel()

	for _, status := range []TransmissionStatus{
		transmissionStatusStopped,
		transmissionStatusSeedWait,
		transmissionStatusSeeding,
	} {
		t.Run(strconv.Itoa(int(status)), func(t *testing.T) {
			t.Parallel()
			record, torrent := correlatedDownloadObservations()
			torrent.Status = status
			torrent.Finished = false
			torrent.Files = append(torrent.Files, TransmissionFile{
				Index:          2,
				Name:           "Example:Movie/optional.txt",
				LengthBytes:    100,
				BytesCompleted: 0,
				Wanted:         false,
			})

			correlation := CorrelateDownload(record, torrent)
			if !correlation.Eligible() {
				t.Fatalf("rejection reasons = %v", correlation.RejectionReasons)
			}
			if correlation.DownloadRoot != "/downloads/Example_Movie" {
				t.Fatalf("download root = %q", correlation.DownloadRoot)
			}
			if !reflect.DeepEqual(correlation.Radarr, record) ||
				!reflect.DeepEqual(correlation.Transmission, torrent) {
				t.Fatal("correlation changed its observations")
			}
		})
	}
}

func TestCorrelateDownloadRejectsInvalidIdentity(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		radarrID    string
		torrentHash string
		wantReasons []CorrelationRejectionReason
	}{
		{
			name:        "invalid Radarr ID",
			radarrID:    "not-a-hash",
			torrentHash: correlationHashLower,
			wantReasons: []CorrelationRejectionReason{CorrelationInvalidRadarrDownloadID},
		},
		{
			name:        "invalid Transmission hash",
			radarrID:    correlationHashUpper,
			torrentHash: "gbcdef0123456789abcdef0123456789abcdef01",
			wantReasons: []CorrelationRejectionReason{CorrelationInvalidTransmissionHash},
		},
		{
			name:        "different hashes",
			radarrID:    correlationHashUpper,
			torrentHash: "abcdef0123456789abcdef0123456789abcdef02",
			wantReasons: []CorrelationRejectionReason{CorrelationDownloadIDMismatch},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			record, torrent := correlatedDownloadObservations()
			record.DownloadID = test.radarrID
			torrent.Hash = test.torrentHash
			correlation := CorrelateDownload(record, torrent)
			if !reflect.DeepEqual(correlation.RejectionReasons, test.wantReasons) {
				t.Fatalf("rejection reasons = %v, want %v", correlation.RejectionReasons, test.wantReasons)
			}
		})
	}
}

func TestCorrelateDownloadRejectsUnstableOrIncompleteTorrent(t *testing.T) {
	t.Parallel()

	for _, status := range []TransmissionStatus{1, 2, 3, 4, 7} {
		t.Run("status "+strconv.Itoa(int(status)), func(t *testing.T) {
			t.Parallel()
			record, torrent := correlatedDownloadObservations()
			torrent.Status = status
			assertCorrelationReasons(t, record, torrent, CorrelationUnstableTorrentState)
		})
	}

	tests := []struct {
		name   string
		mutate func(*TransmissionTorrent)
		want   []CorrelationRejectionReason
	}{
		{
			name: "percent incomplete",
			mutate: func(torrent *TransmissionTorrent) {
				torrent.PercentDone = 0.99
			},
			want: []CorrelationRejectionReason{CorrelationIncompleteTorrent},
		},
		{
			name: "bytes remaining",
			mutate: func(torrent *TransmissionTorrent) {
				torrent.LeftUntilDone = 1
			},
			want: []CorrelationRejectionReason{CorrelationIncompleteTorrent},
		},
		{
			name: "wanted file incomplete",
			mutate: func(torrent *TransmissionTorrent) {
				torrent.Files[0].BytesCompleted--
			},
			want: []CorrelationRejectionReason{CorrelationIncompleteTorrent},
		},
		{
			name: "no wanted files",
			mutate: func(torrent *TransmissionTorrent) {
				for index := range torrent.Files {
					torrent.Files[index].Wanted = false
				}
			},
			want: []CorrelationRejectionReason{CorrelationNoWantedFiles},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			record, torrent := correlatedDownloadObservations()
			test.mutate(&torrent)
			correlation := CorrelateDownload(record, torrent)
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
		mutate func(*RadarrQueueRecord, *TransmissionTorrent)
		want   CorrelationRejectionReason
	}{
		{
			name: "relative Transmission directory",
			mutate: func(_ *RadarrQueueRecord, torrent *TransmissionTorrent) {
				torrent.DownloadDirectory = "downloads"
			},
			want: CorrelationInvalidDownloadRoot,
		},
		{
			name: "unclean Transmission directory",
			mutate: func(_ *RadarrQueueRecord, torrent *TransmissionTorrent) {
				torrent.DownloadDirectory = "/downloads/../downloads"
			},
			want: CorrelationInvalidDownloadRoot,
		},
		{
			name: "torrent name contains a path",
			mutate: func(_ *RadarrQueueRecord, torrent *TransmissionTorrent) {
				torrent.Name = "nested/Example.Movie"
			},
			want: CorrelationInvalidDownloadRoot,
		},
		{
			name: "invalid Radarr root",
			mutate: func(record *RadarrQueueRecord, _ *TransmissionTorrent) {
				record.OutputPath = "/downloads/../Example_Movie"
			},
			want: CorrelationInvalidDownloadRoot,
		},
		{
			name: "different roots",
			mutate: func(record *RadarrQueueRecord, _ *TransmissionTorrent) {
				record.OutputPath = "/downloads/Other.Movie"
			},
			want: CorrelationDownloadRootMismatch,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			record, torrent := correlatedDownloadObservations()
			test.mutate(&record, &torrent)
			correlation := CorrelateDownload(record, torrent)
			if !reflect.DeepEqual(correlation.RejectionReasons, []CorrelationRejectionReason{test.want}) {
				t.Fatalf("rejection reasons = %v, want %v", correlation.RejectionReasons, test.want)
			}
			if correlation.DownloadRoot != "" {
				t.Fatalf("download root = %q", correlation.DownloadRoot)
			}
		})
	}
}

func TestCorrelateDownloadPreservesRejectionOrderAndDeduplicates(t *testing.T) {
	t.Parallel()

	record, torrent := correlatedDownloadObservations()
	record.DownloadID = "invalid"
	torrent.Hash = "also-invalid"
	torrent.Status = 2
	torrent.PercentDone = 0.5
	torrent.LeftUntilDone = 10
	torrent.Files = nil
	torrent.DownloadDirectory = "relative"

	correlation := CorrelateDownload(record, torrent)
	want := []CorrelationRejectionReason{
		CorrelationInvalidRadarrDownloadID,
		CorrelationInvalidTransmissionHash,
		CorrelationUnstableTorrentState,
		CorrelationIncompleteTorrent,
		CorrelationNoWantedFiles,
		CorrelationInvalidDownloadRoot,
	}
	if !reflect.DeepEqual(correlation.RejectionReasons, want) {
		t.Fatalf("rejection reasons = %v, want %v", correlation.RejectionReasons, want)
	}
}

func correlatedDownloadObservations() (RadarrQueueRecord, TransmissionTorrent) {
	record := eligibleCandidateRecord()
	record.DownloadID = correlationHashUpper
	record.OutputPath = "/downloads/Example_Movie"
	torrent := TransmissionTorrent{
		Hash:              correlationHashLower,
		Name:              "Example:Movie",
		Status:            transmissionStatusSeeding,
		PercentDone:       1,
		LeftUntilDone:     0,
		Finished:          false,
		DownloadDirectory: "/downloads",
		Files: []TransmissionFile{
			{
				Index:          0,
				Name:           "Example:Movie/CD1.mkv",
				LengthBytes:    100,
				BytesCompleted: 100,
				Wanted:         true,
			},
			{
				Index:          1,
				Name:           "Example:Movie/CD2.mkv",
				LengthBytes:    200,
				BytesCompleted: 200,
				Wanted:         true,
			},
		},
	}
	return record, torrent
}

func assertCorrelationReasons(
	t *testing.T,
	record RadarrQueueRecord,
	torrent TransmissionTorrent,
	want ...CorrelationRejectionReason,
) {
	t.Helper()
	correlation := CorrelateDownload(record, torrent)
	if !reflect.DeepEqual(correlation.RejectionReasons, want) {
		t.Fatalf("rejection reasons = %v, want %v", correlation.RejectionReasons, want)
	}
}

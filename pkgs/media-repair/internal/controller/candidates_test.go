package controller

import (
	"reflect"
	"testing"
)

func TestClassifyRepairCandidatesAcceptsSupportedLifecycleStates(t *testing.T) {
	t.Parallel()

	for _, state := range []TrackedDownloadState{"importBlocked", "importPending"} {
		t.Run(string(state), func(t *testing.T) {
			t.Parallel()
			record := eligibleCandidateRecord()
			record.TrackedDownloadState = state
			if reasons := record.RejectionReasons(true); len(reasons) != 0 {
				t.Fatalf("rejection reasons = %v", reasons)
			}
		})
	}
}

func TestClassifyRepairCandidatesRejectsInvalidFacts(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*RadarrQueueRecord)
		want   []CandidateRejectionReason
	}{
		{
			name: "active download",
			mutate: func(record *RadarrQueueRecord) {
				record.Status = "downloading"
				record.TrackedDownloadStatus = "ok"
				record.TrackedDownloadState = "downloading"
				record.SizeRemainingBytes = 1024
			},
			want: []CandidateRejectionReason{
				CandidateIncompleteDownload,
				CandidateUnsupportedQueueState,
			},
		},
		{
			name: "completed item still has bytes remaining",
			mutate: func(record *RadarrQueueRecord) {
				record.SizeRemainingBytes = 1
			},
			want: []CandidateRejectionReason{CandidateIncompleteDownload},
		},
		{
			name: "error status",
			mutate: func(record *RadarrQueueRecord) {
				record.TrackedDownloadStatus = "error"
			},
			want: []CandidateRejectionReason{CandidateUnsupportedQueueState},
		},
		{
			name: "future queue state",
			mutate: func(record *RadarrQueueRecord) {
				record.TrackedDownloadState = "futureState"
			},
			want: []CandidateRejectionReason{CandidateUnsupportedQueueState},
		},
		{
			name: "empty download ID",
			mutate: func(record *RadarrQueueRecord) {
				record.DownloadID = ""
			},
			want: []CandidateRejectionReason{CandidateMissingDownloadID},
		},
		{
			name: "padded download ID",
			mutate: func(record *RadarrQueueRecord) {
				record.DownloadID = " torrent-id "
			},
			want: []CandidateRejectionReason{CandidateMissingDownloadID},
		},
		{
			name: "relative output path",
			mutate: func(record *RadarrQueueRecord) {
				record.OutputPath = "downloads/Movie"
			},
			want: []CandidateRejectionReason{CandidateInvalidOutputPath},
		},
		{
			name: "unclean output path",
			mutate: func(record *RadarrQueueRecord) {
				record.OutputPath = "/downloads/../Movie"
			},
			want: []CandidateRejectionReason{CandidateInvalidOutputPath},
		},
		{
			name: "root output path",
			mutate: func(record *RadarrQueueRecord) {
				record.OutputPath = "/"
			},
			want: []CandidateRejectionReason{CandidateInvalidOutputPath},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			record := eligibleCandidateRecord()
			test.mutate(&record)
			if reasons := record.RejectionReasons(true); !reflect.DeepEqual(reasons, test.want) {
				t.Fatalf("rejection reasons = %v, want %v", reasons, test.want)
			}
		})
	}
}

func TestClassifyRepairCandidatesRejectsOtherLifecycleStates(t *testing.T) {
	t.Parallel()

	states := []TrackedDownloadState{
		"downloading", "importing", "imported", "failedPending", "failed", "ignored",
	}
	for _, state := range states {
		t.Run(string(state), func(t *testing.T) {
			t.Parallel()
			record := eligibleCandidateRecord()
			record.TrackedDownloadState = state
			want := []CandidateRejectionReason{CandidateUnsupportedQueueState}
			if reasons := record.RejectionReasons(true); !reflect.DeepEqual(reasons, want) {
				t.Fatalf("rejection reasons = %v, want %v", reasons, want)
			}
		})
	}
}

func TestClassifyRepairCandidatesIgnoresMovieAndMessageEvidence(t *testing.T) {
	t.Parallel()

	record := eligibleCandidateRecord()
	record.MovieID = nil
	record.ErrorMessage = "A diagnostic from the download client"
	record.StatusMessages = []RadarrStatusMessage{
		{Title: "first", Messages: []string{}},
		{Title: "second", Messages: []string{"diagnostic one", "diagnostic two"}},
	}
	if reasons := record.RejectionReasons(true); len(reasons) != 0 {
		t.Fatalf("rejection reasons = %v", reasons)
	}
}

func eligibleCandidateRecord() RadarrQueueRecord {
	movieID := int64(42)
	return RadarrQueueRecord{
		ID:                    101,
		MovieID:               &movieID,
		Title:                 "Movie",
		Status:                "completed",
		TrackedDownloadStatus: "warning",
		TrackedDownloadState:  "importBlocked",
		SizeRemainingBytes:    0,
		DownloadID:            "torrent-id",
		Protocol:              "torrent",
		DownloadClient:        "Transmission",
		OutputPath:            "/downloads/Movie",
		StatusMessages: []RadarrStatusMessage{
			{Title: "Movie.mkv", Messages: []string{"diagnostic"}},
		},
	}
}

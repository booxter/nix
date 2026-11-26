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
			assessment := ClassifyRepairCandidate(record, testDownloadSupport{})
			if !assessment.Eligible() {
				t.Fatalf("rejection reasons = %v", assessment.RejectionReasons)
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
			name: "usenet",
			mutate: func(record *RadarrQueueRecord) {
				record.Protocol = "usenet"
			},
			want: []CandidateRejectionReason{CandidateUnsupportedSource},
		},
		{
			name: "future protocol",
			mutate: func(record *RadarrQueueRecord) {
				record.Protocol = "futureProtocol"
			},
			want: []CandidateRejectionReason{CandidateUnsupportedSource},
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
			assessment := ClassifyRepairCandidate(record, testDownloadSupport{})
			if assessment.Eligible() {
				t.Fatal("record was eligible")
			}
			if !reflect.DeepEqual(assessment.RejectionReasons, test.want) {
				t.Fatalf("rejection reasons = %v, want %v", assessment.RejectionReasons, test.want)
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
			assessment := ClassifyRepairCandidate(record, testDownloadSupport{})
			want := []CandidateRejectionReason{CandidateUnsupportedQueueState}
			if !reflect.DeepEqual(assessment.RejectionReasons, want) {
				t.Fatalf("rejection reasons = %v, want %v", assessment.RejectionReasons, want)
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
	assessment := ClassifyRepairCandidate(record, testDownloadSupport{})
	if !assessment.Eligible() {
		t.Fatalf("rejection reasons = %v", assessment.RejectionReasons)
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

type testDownloadSupport struct{}

func (testDownloadSupport) Supports(protocol DownloadProtocol, clientName string) bool {
	return protocol == "torrent" && clientName == "Transmission"
}

package controller

import (
	"reflect"
	"testing"
)

func TestClassifyRepairCandidatesAcceptsRadarrMultiPartRejection(t *testing.T) {
	t.Parallel()

	record := eligibleCandidateRecord()
	record.StatusMessages = []RadarrStatusMessage{
		{
			Title: "Movie-part1.mkv",
			Messages: []string{
				"  file IS suspected MULTI-part file, radarr DOESN'T support THIS  ",
			},
		},
		{
			Title:    "One or more movies expected in this release were not imported or missing",
			Messages: []string{},
		},
	}

	assessments := ClassifyRepairCandidates([]RadarrQueueRecord{record})
	if len(assessments) != 1 {
		t.Fatalf("assessments = %d", len(assessments))
	}
	if !assessments[0].Eligible() {
		t.Fatalf("rejection reasons = %v", assessments[0].RejectionReasons)
	}
	if !reflect.DeepEqual(assessments[0].Record, record) {
		t.Fatalf("record changed: %#v", assessments[0].Record)
	}
}

func TestClassifyRepairCandidatesRejectsInvalidFacts(t *testing.T) {
	t.Parallel()

	zeroMovieID := int64(0)
	tests := []struct {
		name   string
		mutate func(*RadarrQueueRecord)
		want   []CandidateRejectionReason
	}{
		{
			name: "active download",
			mutate: func(record *RadarrQueueRecord) {
				record.Status = QueueStatus("downloading")
				record.TrackedDownloadStatus = TrackedDownloadStatus("ok")
				record.TrackedDownloadState = TrackedDownloadState("downloading")
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
				record.Protocol = DownloadProtocol("usenet")
			},
			want: []CandidateRejectionReason{CandidateUnsupportedProtocol},
		},
		{
			name: "future protocol",
			mutate: func(record *RadarrQueueRecord) {
				record.Protocol = DownloadProtocol("futureProtocol")
			},
			want: []CandidateRejectionReason{CandidateUnsupportedProtocol},
		},
		{
			name: "error status",
			mutate: func(record *RadarrQueueRecord) {
				record.TrackedDownloadStatus = TrackedDownloadStatus("error")
			},
			want: []CandidateRejectionReason{CandidateUnsupportedQueueState},
		},
		{
			name: "future queue state",
			mutate: func(record *RadarrQueueRecord) {
				record.TrackedDownloadState = TrackedDownloadState("futureState")
			},
			want: []CandidateRejectionReason{CandidateUnsupportedQueueState},
		},
		{
			name: "missing movie ID",
			mutate: func(record *RadarrQueueRecord) {
				record.MovieID = nil
			},
			want: []CandidateRejectionReason{CandidateMissingMovieID},
		},
		{
			name: "zero movie ID",
			mutate: func(record *RadarrQueueRecord) {
				record.MovieID = &zeroMovieID
			},
			want: []CandidateRejectionReason{CandidateMissingMovieID},
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
		{
			name: "download client error",
			mutate: func(record *RadarrQueueRecord) {
				record.ErrorMessage = "download client unavailable"
			},
			want: []CandidateRejectionReason{CandidateDownloadClientError},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			record := eligibleCandidateRecord()
			test.mutate(&record)
			assessment := ClassifyRepairCandidates([]RadarrQueueRecord{record})[0]
			if assessment.Eligible() {
				t.Fatal("record was eligible")
			}
			if !reflect.DeepEqual(assessment.RejectionReasons, test.want) {
				t.Fatalf("rejection reasons = %v, want %v", assessment.RejectionReasons, test.want)
			}
		})
	}
}

func TestClassifyRepairCandidatesRequiresExactMessageBody(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		messages []RadarrStatusMessage
	}{
		{name: "no messages"},
		{
			name: "marker in title only",
			messages: []RadarrStatusMessage{
				{Title: radarrMultiPartRejection},
			},
		},
		{
			name: "partial marker",
			messages: []RadarrStatusMessage{
				{Title: "Movie-part1.mkv", Messages: []string{"File is suspected multi-part file"}},
			},
		},
		{
			name: "unrelated import failure",
			messages: []RadarrStatusMessage{
				{Title: "Movie.mkv", Messages: []string{"Unable to parse file"}},
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			record := eligibleCandidateRecord()
			record.StatusMessages = test.messages
			assessment := ClassifyRepairCandidates([]RadarrQueueRecord{record})[0]
			want := []CandidateRejectionReason{CandidateUnsupportedImportError}
			if !reflect.DeepEqual(assessment.RejectionReasons, want) {
				t.Fatalf("rejection reasons = %v, want %v", assessment.RejectionReasons, want)
			}
		})
	}
}

func TestClassifyRepairCandidatesRejectsMixedFailuresOnceAndPreservesOrder(t *testing.T) {
	t.Parallel()

	first := eligibleCandidateRecord()
	first.ID = 1
	first.Protocol = DownloadProtocol("usenet")
	first.StatusMessages[0].Messages = append(
		first.StatusMessages[0].Messages,
		"Unable to parse file",
		"Unable to parse file",
	)
	second := eligibleCandidateRecord()
	second.ID = 2

	assessments := ClassifyRepairCandidates([]RadarrQueueRecord{first, second})
	if len(assessments) != 2 || assessments[0].Record.ID != 1 || assessments[1].Record.ID != 2 {
		t.Fatalf("assessment order = %#v", assessments)
	}
	want := []CandidateRejectionReason{
		CandidateUnsupportedProtocol,
		CandidateUnsupportedImportError,
	}
	if !reflect.DeepEqual(assessments[0].RejectionReasons, want) {
		t.Fatalf("rejection reasons = %v, want %v", assessments[0].RejectionReasons, want)
	}
	if !assessments[1].Eligible() {
		t.Fatalf("second rejection reasons = %v", assessments[1].RejectionReasons)
	}
}

func eligibleCandidateRecord() RadarrQueueRecord {
	movieID := int64(42)
	return RadarrQueueRecord{
		ID:                    101,
		MovieID:               &movieID,
		Title:                 "Movie",
		Status:                QueueStatus("completed"),
		TrackedDownloadStatus: TrackedDownloadStatus("warning"),
		TrackedDownloadState:  TrackedDownloadState("importBlocked"),
		SizeRemainingBytes:    0,
		DownloadID:            "torrent-id",
		Protocol:              DownloadProtocol("torrent"),
		OutputPath:            "/downloads/Movie",
		StatusMessages: []RadarrStatusMessage{
			{Title: "Movie-part1.mkv", Messages: []string{radarrMultiPartRejection}},
		},
	}
}

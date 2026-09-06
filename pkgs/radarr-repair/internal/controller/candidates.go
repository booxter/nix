package controller

import (
	"path/filepath"
	"strings"
)

const radarrMultiPartRejection = "File is suspected multi-part file, Radarr doesn't support this"

type CandidateRejectionReason string

const (
	CandidateUnsupportedProtocol    CandidateRejectionReason = "unsupported_protocol"
	CandidateIncompleteDownload     CandidateRejectionReason = "incomplete_download"
	CandidateUnsupportedQueueState  CandidateRejectionReason = "unsupported_queue_state"
	CandidateMissingMovieID         CandidateRejectionReason = "missing_movie_id"
	CandidateMissingDownloadID      CandidateRejectionReason = "missing_download_id"
	CandidateInvalidOutputPath      CandidateRejectionReason = "invalid_output_path"
	CandidateDownloadClientError    CandidateRejectionReason = "download_client_error"
	CandidateUnsupportedImportError CandidateRejectionReason = "unsupported_import_failure"
)

type CandidateAssessment struct {
	Record           RadarrQueueRecord
	RejectionReasons []CandidateRejectionReason
}

func (assessment CandidateAssessment) Eligible() bool {
	return len(assessment.RejectionReasons) == 0
}

type candidateQueueState struct {
	status        QueueStatus
	trackedStatus TrackedDownloadStatus
	trackedState  TrackedDownloadState
}

var eligibleQueueStates = [...]candidateQueueState{
	{
		status:        QueueStatus("completed"),
		trackedStatus: TrackedDownloadStatus("warning"),
		trackedState:  TrackedDownloadState("importBlocked"),
	},
}

func ClassifyRepairCandidates(records []RadarrQueueRecord) []CandidateAssessment {
	assessments := make([]CandidateAssessment, len(records))
	for index, record := range records {
		assessments[index] = classifyRepairCandidate(record)
	}
	return assessments
}

func classifyRepairCandidate(record RadarrQueueRecord) CandidateAssessment {
	assessment := CandidateAssessment{Record: record}
	addReason := func(reason CandidateRejectionReason) {
		for _, existing := range assessment.RejectionReasons {
			if existing == reason {
				return
			}
		}
		assessment.RejectionReasons = append(assessment.RejectionReasons, reason)
	}

	if record.Protocol != DownloadProtocol("torrent") {
		addReason(CandidateUnsupportedProtocol)
	}
	if record.Status != QueueStatus("completed") || record.SizeRemainingBytes != 0 {
		addReason(CandidateIncompleteDownload)
	}
	if !eligibleQueueState(record) {
		addReason(CandidateUnsupportedQueueState)
	}
	if record.MovieID == nil || *record.MovieID <= 0 {
		addReason(CandidateMissingMovieID)
	}
	if !usableDownloadID(record.DownloadID) {
		addReason(CandidateMissingDownloadID)
	}
	if !usableOutputPath(record.OutputPath) {
		addReason(CandidateInvalidOutputPath)
	}
	if strings.TrimSpace(record.ErrorMessage) != "" {
		addReason(CandidateDownloadClientError)
	}

	foundMultiPart := false
	foundImportMessage := false
	for _, statusMessage := range record.StatusMessages {
		// Radarr status-message titles are filenames or release names. Only message
		// bodies carry import rejection text, so titles cannot establish eligibility.
		for _, message := range statusMessage.Messages {
			normalized := strings.TrimSpace(message)
			if normalized == "" {
				continue
			}
			foundImportMessage = true
			if strings.EqualFold(normalized, radarrMultiPartRejection) {
				foundMultiPart = true
				continue
			}
			addReason(CandidateUnsupportedImportError)
		}
	}

	// Radarr retains the structured MultiPartMovie rejection internally but its
	// queue API exposes only the rendered message. Match that complete upstream
	// message because neither Starr nor the API provides the rejection enum.
	if !foundMultiPart && !foundImportMessage {
		addReason(CandidateUnsupportedImportError)
	}

	return assessment
}

func eligibleQueueState(record RadarrQueueRecord) bool {
	actual := candidateQueueState{
		status:        record.Status,
		trackedStatus: record.TrackedDownloadStatus,
		trackedState:  record.TrackedDownloadState,
	}
	for _, eligible := range eligibleQueueStates {
		if actual == eligible {
			return true
		}
	}
	return false
}

func usableDownloadID(downloadID string) bool {
	return downloadID != "" && strings.TrimSpace(downloadID) == downloadID &&
		!strings.ContainsRune(downloadID, '\x00')
}

func usableOutputPath(outputPath string) bool {
	if outputPath == "" || strings.TrimSpace(outputPath) != outputPath ||
		strings.ContainsRune(outputPath, '\x00') || !filepath.IsAbs(outputPath) {
		return false
	}
	cleaned := filepath.Clean(outputPath)
	return cleaned == outputPath && cleaned != string(filepath.Separator)
}

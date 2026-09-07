package controller

import (
	"path/filepath"
	"strings"
)

type CandidateRejectionReason string

const (
	CandidateUnsupportedProtocol   CandidateRejectionReason = "unsupported_protocol"
	CandidateIncompleteDownload    CandidateRejectionReason = "incomplete_download"
	CandidateUnsupportedQueueState CandidateRejectionReason = "unsupported_queue_state"
	CandidateMissingDownloadID     CandidateRejectionReason = "missing_download_id"
	CandidateInvalidOutputPath     CandidateRejectionReason = "invalid_output_path"
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
	{
		status:        QueueStatus("completed"),
		trackedStatus: TrackedDownloadStatus("warning"),
		trackedState:  TrackedDownloadState("importPending"),
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
	if !usableDownloadID(record.DownloadID) {
		addReason(CandidateMissingDownloadID)
	}
	if !usableOutputPath(record.OutputPath) {
		addReason(CandidateInvalidOutputPath)
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

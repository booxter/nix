package controller

import (
	"path/filepath"
	"strings"
)

type CandidateRejectionReason string

const (
	CandidateUnsupportedSource     CandidateRejectionReason = "unsupported_download_source"
	CandidateIncompleteDownload    CandidateRejectionReason = "incomplete_download"
	CandidateUnsupportedQueueState CandidateRejectionReason = "unsupported_queue_state"
	CandidateMissingDownloadID     CandidateRejectionReason = "missing_download_id"
	CandidateInvalidOutputPath     CandidateRejectionReason = "invalid_output_path"
)

// Radarr names the download client in its queue. Repairr's configuration
// determines whether that client is supported.
type queueCandidate struct {
	RadarrQueueRecord
	sourceSupported bool
}

var queueChecks = [...]struct {
	passes func(queueCandidate) bool
	reason CandidateRejectionReason
}{
	{queueCandidate.hasSupportedSource, CandidateUnsupportedSource},
	{queueCandidate.downloadComplete, CandidateIncompleteDownload},
	{queueCandidate.hasEligibleQueueState, CandidateUnsupportedQueueState},
	{queueCandidate.HasDownloadID, CandidateMissingDownloadID},
	{queueCandidate.hasUsableOutputPath, CandidateInvalidOutputPath},
}

// RejectionReasons lists every reason to skip this queue entry so the operator can see them together.
func (record RadarrQueueRecord) RejectionReasons(sourceSupported bool) []CandidateRejectionReason {
	candidate := queueCandidate{RadarrQueueRecord: record, sourceSupported: sourceSupported}
	var reasons []CandidateRejectionReason
	for _, check := range queueChecks {
		if !check.passes(candidate) {
			reasons = append(reasons, check.reason)
		}
	}
	return reasons
}

func (candidate queueCandidate) hasSupportedSource() bool {
	return candidate.sourceSupported
}

func (record RadarrQueueRecord) downloadComplete() bool {
	return record.Status == "completed" && record.SizeRemainingBytes == 0
}

// Radarr must have finished the download and reported a warning about its import.
func (record RadarrQueueRecord) hasEligibleQueueState() bool {
	return record.Status == "completed" && record.TrackedDownloadStatus == "warning" &&
		(record.TrackedDownloadState == "importBlocked" || record.TrackedDownloadState == "importPending")
}

// HasDownloadID checks that we can look up the ID exactly as Radarr supplied it.
func (record RadarrQueueRecord) HasDownloadID() bool {
	downloadID := record.DownloadID
	return downloadID != "" && strings.TrimSpace(downloadID) == downloadID &&
		!strings.ContainsRune(downloadID, '\x00')
}

func (record RadarrQueueRecord) hasUsableOutputPath() bool {
	return usableOutputPath(record.OutputPath)
}

// usableOutputPath requires a clean, absolute path below the filesystem root.
func usableOutputPath(outputPath string) bool {
	if outputPath == "" || strings.TrimSpace(outputPath) != outputPath ||
		strings.ContainsRune(outputPath, '\x00') || !filepath.IsAbs(outputPath) {
		return false
	}
	cleaned := filepath.Clean(outputPath)
	return cleaned == outputPath && cleaned != string(filepath.Separator)
}

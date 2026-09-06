package controller

import (
	"path"
	"strings"
)

type MediaExtension string

const (
	MediaExtensionTS  MediaExtension = "ts"
	MediaExtensionMP4 MediaExtension = "mp4"
	MediaExtensionMKV MediaExtension = "mkv"
	MediaExtensionAVI MediaExtension = "avi"
)

type MediaFileDisposition string

const (
	MediaFileProbeCandidate MediaFileDisposition = "probe_candidate"
	MediaFileEvidenceOnly   MediaFileDisposition = "evidence_only"
)

type MediaFileExclusionReason string

const (
	MediaFileUntracked            MediaFileExclusionReason = "untracked"
	MediaFileUnwanted             MediaFileExclusionReason = "unwanted"
	MediaFileIncomplete           MediaFileExclusionReason = "incomplete"
	MediaFileEmpty                MediaFileExclusionReason = "empty"
	MediaFileUnsupportedExtension MediaFileExclusionReason = "unsupported_extension"
)

type MediaFileAssessment struct {
	File            InventoryFile
	Extension       MediaExtension
	Disposition     MediaFileDisposition
	ExclusionReason MediaFileExclusionReason
}

func (assessment MediaFileAssessment) ProbeCandidate() bool {
	return assessment.Disposition == MediaFileProbeCandidate
}

func ClassifyMediaFiles(inventory FileInventory) []MediaFileAssessment {
	assessments := make([]MediaFileAssessment, len(inventory.Files))
	for index, file := range inventory.Files {
		assessments[index] = classifyMediaFile(file)
	}
	return assessments
}

func classifyMediaFile(file InventoryFile) MediaFileAssessment {
	assessment := MediaFileAssessment{
		File:        file,
		Disposition: MediaFileEvidenceOnly,
	}
	if file.TorrentFile == nil {
		assessment.ExclusionReason = MediaFileUntracked
		return assessment
	}
	if !file.TorrentFile.Wanted {
		assessment.ExclusionReason = MediaFileUnwanted
		return assessment
	}
	if file.TorrentFile.BytesCompleted != file.TorrentFile.LengthBytes {
		assessment.ExclusionReason = MediaFileIncomplete
		return assessment
	}
	if file.Fingerprint.SizeBytes <= 0 || file.TorrentFile.LengthBytes <= 0 {
		assessment.ExclusionReason = MediaFileEmpty
		return assessment
	}

	extension, supported := supportedMediaExtension(file.PathComponents)
	if !supported {
		assessment.ExclusionReason = MediaFileUnsupportedExtension
		return assessment
	}

	assessment.Extension = extension
	assessment.Disposition = MediaFileProbeCandidate
	return assessment
}

func supportedMediaExtension(pathComponents []string) (MediaExtension, bool) {
	if len(pathComponents) == 0 {
		return "", false
	}

	// Radarr recognizes more media extensions. Repair v1 deliberately narrows
	// this set to the containers represented by its contract and join analyzer.
	switch strings.ToLower(path.Ext(pathComponents[len(pathComponents)-1])) {
	case ".ts":
		return MediaExtensionTS, true
	case ".mp4":
		return MediaExtensionMP4, true
	case ".mkv":
		return MediaExtensionMKV, true
	case ".avi":
		return MediaExtensionAVI, true
	default:
		return "", false
	}
}

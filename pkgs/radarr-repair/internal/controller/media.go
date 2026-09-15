package controller

import (
	"path"
	"strings"
)

type MediaExtension string

const (
	MediaExtensionTS   MediaExtension = "ts"
	MediaExtensionM2TS MediaExtension = "m2ts"
	MediaExtensionMP4  MediaExtension = "mp4"
	MediaExtensionMKV  MediaExtension = "mkv"
	MediaExtensionAVI  MediaExtension = "avi"
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

func SupportsJoinPartsPath(pathComponents []string) bool {
	return len(pathComponents) != 0 && !isRawDiscPath(pathComponents)
}

func isRawDiscPath(pathComponents []string) bool {
	if len(pathComponents) == 0 {
		return false
	}
	for _, component := range pathComponents[:len(pathComponents)-1] {
		switch strings.ToUpper(component) {
		case "BDMV", "VIDEO_TS":
			// Raw discs require playlist or title selection. Treating one stream
			// file as a standalone movie or linear part is unsafe.
			return true
		}
	}
	return false
}

func classifyMediaFile(file InventoryFile) MediaFileAssessment {
	assessment := MediaFileAssessment{
		File:        file,
		Disposition: MediaFileEvidenceOnly,
	}
	extension, supported := supportedMediaExtension(file.PathComponents)
	if supported {
		assessment.Extension = extension
	}
	if file.DownloadFile == nil {
		assessment.ExclusionReason = MediaFileUntracked
		return assessment
	}
	if !file.DownloadFile.Selected {
		assessment.ExclusionReason = MediaFileUnwanted
		return assessment
	}
	if file.DownloadFile.BytesCompleted != file.DownloadFile.LengthBytes {
		assessment.ExclusionReason = MediaFileIncomplete
		return assessment
	}
	if file.Fingerprint.SizeBytes <= 0 || file.DownloadFile.LengthBytes <= 0 {
		assessment.ExclusionReason = MediaFileEmpty
		return assessment
	}

	if !supported {
		assessment.ExclusionReason = MediaFileUnsupportedExtension
		return assessment
	}

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
	case ".m2ts":
		return MediaExtensionM2TS, true
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

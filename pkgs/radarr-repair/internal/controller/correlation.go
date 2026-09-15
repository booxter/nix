package controller

type CorrelationRejectionReason string

const (
	CorrelationInvalidRadarrDownloadID CorrelationRejectionReason = "invalid_radarr_download_id"
	CorrelationInvalidDownloadID       CorrelationRejectionReason = "invalid_download_id"
	CorrelationDownloadIDMismatch      CorrelationRejectionReason = "download_id_mismatch"
	CorrelationUnstableDownload        CorrelationRejectionReason = "unstable_download"
	CorrelationIncompleteDownload      CorrelationRejectionReason = "incomplete_download"
	CorrelationNoSelectedFiles         CorrelationRejectionReason = "no_selected_files"
	CorrelationInvalidDownloadRoot     CorrelationRejectionReason = "invalid_download_root"
	CorrelationDownloadRootMismatch    CorrelationRejectionReason = "download_root_mismatch"
)

type DownloadCorrelation struct {
	Radarr           RadarrQueueRecord
	Download         Download
	DownloadRoot     string
	RejectionReasons []CorrelationRejectionReason
}

func (correlation DownloadCorrelation) Eligible() bool {
	return len(correlation.RejectionReasons) == 0
}

func CorrelateDownload(
	record RadarrQueueRecord,
	download Download,
) DownloadCorrelation {
	correlation := DownloadCorrelation{
		Radarr:   record,
		Download: download,
	}
	addReason := func(reason CorrelationRejectionReason) {
		for _, existing := range correlation.RejectionReasons {
			if existing == reason {
				return
			}
		}
		correlation.RejectionReasons = append(correlation.RejectionReasons, reason)
	}

	if record.DownloadID == "" {
		addReason(CorrelationInvalidRadarrDownloadID)
	}
	validDownloadID := download.ID != "" &&
		(download.IDComparison == DownloadIDExact ||
			download.IDComparison == DownloadIDASCIIInsensitive)
	if !validDownloadID {
		addReason(CorrelationInvalidDownloadID)
	}
	if record.DownloadID != "" && validDownloadID && !download.MatchesID(record.DownloadID) {
		addReason(CorrelationDownloadIDMismatch)
	}

	if !download.Stable {
		addReason(CorrelationUnstableDownload)
	}
	if !download.Complete {
		addReason(CorrelationIncompleteDownload)
	}
	if download.ContentOwnership == DownloadContentManifest {
		selectedFiles := 0
		for _, file := range download.Files {
			if !file.Selected {
				continue
			}
			selectedFiles++
			if file.BytesCompleted != file.LengthBytes {
				addReason(CorrelationIncompleteDownload)
			}
		}
		if selectedFiles == 0 {
			addReason(CorrelationNoSelectedFiles)
		}
	}

	validDownloadRoot := usableOutputPath(download.OutputPath)
	validRadarrRoot := usableOutputPath(record.OutputPath)
	if !validDownloadRoot || !validRadarrRoot {
		addReason(CorrelationInvalidDownloadRoot)
	} else if download.OutputPath != record.OutputPath {
		addReason(CorrelationDownloadRootMismatch)
	} else {
		correlation.DownloadRoot = record.OutputPath
	}

	return correlation
}

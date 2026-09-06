package controller

import (
	"path/filepath"
	"strings"
)

const (
	transmissionStatusStopped  TransmissionStatus = 0
	transmissionStatusSeedWait TransmissionStatus = 5
	transmissionStatusSeeding  TransmissionStatus = 6
)

type CorrelationRejectionReason string

const (
	CorrelationInvalidRadarrDownloadID CorrelationRejectionReason = "invalid_radarr_download_id"
	CorrelationInvalidTransmissionHash CorrelationRejectionReason = "invalid_transmission_hash"
	CorrelationDownloadIDMismatch      CorrelationRejectionReason = "download_id_mismatch"
	CorrelationUnstableTorrentState    CorrelationRejectionReason = "unstable_torrent_state"
	CorrelationIncompleteTorrent       CorrelationRejectionReason = "incomplete_torrent"
	CorrelationNoWantedFiles           CorrelationRejectionReason = "no_wanted_files"
	CorrelationInvalidDownloadRoot     CorrelationRejectionReason = "invalid_download_root"
	CorrelationDownloadRootMismatch    CorrelationRejectionReason = "download_root_mismatch"
)

type DownloadCorrelation struct {
	Radarr           RadarrQueueRecord
	Transmission     TransmissionTorrent
	DownloadRoot     string
	RejectionReasons []CorrelationRejectionReason
}

func (correlation DownloadCorrelation) Eligible() bool {
	return len(correlation.RejectionReasons) == 0
}

func CorrelateDownload(
	record RadarrQueueRecord,
	torrent TransmissionTorrent,
) DownloadCorrelation {
	correlation := DownloadCorrelation{
		Radarr:       record,
		Transmission: torrent,
	}
	addReason := func(reason CorrelationRejectionReason) {
		for _, existing := range correlation.RejectionReasons {
			if existing == reason {
				return
			}
		}
		correlation.RejectionReasons = append(correlation.RejectionReasons, reason)
	}

	radarrID, validRadarrID := normalizeInfoHash(record.DownloadID)
	if !validRadarrID {
		addReason(CorrelationInvalidRadarrDownloadID)
	}
	transmissionHash, validTransmissionHash := normalizeInfoHash(torrent.Hash)
	if !validTransmissionHash {
		addReason(CorrelationInvalidTransmissionHash)
	}
	if validRadarrID && validTransmissionHash && radarrID != transmissionHash {
		addReason(CorrelationDownloadIDMismatch)
	}

	if !stableTorrentStatus(torrent.Status) {
		addReason(CorrelationUnstableTorrentState)
	}
	if torrent.PercentDone != 1 || torrent.LeftUntilDone != 0 {
		addReason(CorrelationIncompleteTorrent)
	}
	wantedFiles := 0
	for _, file := range torrent.Files {
		if !file.Wanted {
			continue
		}
		wantedFiles++
		if file.BytesCompleted != file.LengthBytes {
			addReason(CorrelationIncompleteTorrent)
		}
	}
	if wantedFiles == 0 {
		addReason(CorrelationNoWantedFiles)
	}

	expectedRoot, validTransmissionRoot := transmissionDownloadRoot(torrent)
	validRadarrRoot := usableOutputPath(record.OutputPath)
	if !validTransmissionRoot || !validRadarrRoot {
		addReason(CorrelationInvalidDownloadRoot)
	} else if expectedRoot != record.OutputPath {
		addReason(CorrelationDownloadRootMismatch)
	} else {
		correlation.DownloadRoot = record.OutputPath
	}

	return correlation
}

func normalizeInfoHash(value string) (string, bool) {
	// Radarr uppercases Transmission's SHA-1 hash_string. Normalize only case;
	// accepting names or partial hashes would weaken this identity check.
	if len(value) != 40 {
		return "", false
	}
	for _, character := range value {
		if !((character >= '0' && character <= '9') ||
			(character >= 'a' && character <= 'f') ||
			(character >= 'A' && character <= 'F')) {
			return "", false
		}
	}
	return strings.ToLower(value), true
}

func stableTorrentStatus(status TransmissionStatus) bool {
	return status == transmissionStatusStopped ||
		status == transmissionStatusSeedWait ||
		status == transmissionStatusSeeding
}

func transmissionDownloadRoot(torrent TransmissionTorrent) (string, bool) {
	directory := torrent.DownloadDirectory
	if directory == "" || strings.TrimSpace(directory) != directory ||
		strings.ContainsRune(directory, '\x00') || !filepath.IsAbs(directory) ||
		filepath.Clean(directory) != directory {
		return "", false
	}
	name := torrent.Name
	if name == "" || strings.ContainsRune(name, '\x00') ||
		strings.ContainsRune(name, filepath.Separator) || filepath.Base(name) != name ||
		name == "." || name == ".." {
		return "", false
	}

	// Radarr's Transmission adapter applies this replacement when it builds the
	// queue output path. Reproduce that exact operation before comparing roots.
	name = strings.ReplaceAll(name, ":", "_")
	root := filepath.Join(directory, name)
	if !usableOutputPath(root) {
		return "", false
	}
	return root, true
}

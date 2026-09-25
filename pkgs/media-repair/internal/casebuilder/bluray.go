package casebuilder

import (
	"fmt"
	"strconv"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
)

func bindBluRayCapabilities(
	playlists []mkvmerge.Candidate,
	files map[controller.FileID]controller.InventoryFile,
) ([]contracts.Capability, error) {
	if len(playlists) > 128 {
		return nil, fmt.Errorf("too many Blu-ray playlist candidates")
	}
	capabilities := make([]contracts.Capability, 0, len(playlists))
	seen := make(map[controller.FileID]bool, len(playlists))
	for _, playlist := range playlists {
		file, exists := files[playlist.PlaylistFileID]
		if !exists || seen[playlist.PlaylistFileID] {
			return nil, fmt.Errorf("Blu-ray playlist is missing or duplicated in inventory")
		}
		seen[playlist.PlaylistFileID] = true
		if len(playlist.ClipFileIDs) == 0 || len(playlist.ClipFileIDs) > 1024 {
			return nil, fmt.Errorf("Blu-ray playlist has an invalid clip count")
		}

		clipIDs := make([]string, 0, len(playlist.ClipFileIDs))
		identity := []string{
			string(contracts.CapabilityActionRemuxBluray),
			string(playlist.PlaylistFileID),
			file.Fingerprint.StableFingerprint(),
			strconv.FormatInt(playlist.Details.DurationMS, 10),
			strconv.Itoa(playlist.Details.Chapters),
		}
		for _, clipID := range playlist.ClipFileIDs {
			clip, exists := files[clipID]
			if !exists {
				return nil, fmt.Errorf("Blu-ray clip %q is missing from inventory", clipID)
			}
			clipIDs = append(clipIDs, string(clipID))
			identity = append(identity, string(clipID), clip.Fingerprint.StableFingerprint())
		}
		tracks, err := mapBluRayTracks(playlist.Details.Tracks)
		if err != nil {
			return nil, err
		}
		playlistID := string(playlist.PlaylistFileID)
		duration := playlist.Details.DurationMS
		chapters := int64(playlist.Details.Chapters)
		capabilities = append(capabilities, contracts.Capability{
			Action:         contracts.CapabilityActionRemuxBluray,
			CapabilityID:   opaqueID("capability", identity...),
			PlaylistFileID: &playlistID,
			ClipFileIDS:    clipIDs,
			DurationMS:     &duration,
			ChapterCount:   &chapters,
			Tracks:         tracks,
		})
	}
	return capabilities, nil
}

func mapBluRayTracks(tracks []mkvmerge.Track) ([]contracts.TrackElement, error) {
	if len(tracks) == 0 || len(tracks) > 32 {
		return nil, fmt.Errorf("Blu-ray playlist has an invalid track count")
	}
	mapped := make([]contracts.TrackElement, 0, len(tracks))
	for _, track := range tracks {
		if track.Codec == "" ||
			(track.Kind != "video" && track.Kind != "audio" && track.Kind != "subtitles") {
			return nil, fmt.Errorf("Blu-ray playlist has an invalid track")
		}
		var language *string
		if track.Language != "" {
			language = &track.Language
		}
		mapped = append(mapped, contracts.TrackElement{
			Kind:     contracts.TrackKind(track.Kind),
			Codec:    track.Codec,
			Language: language,
		})
	}
	return mapped, nil
}

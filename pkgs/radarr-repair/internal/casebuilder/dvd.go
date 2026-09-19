package casebuilder

import (
	"fmt"
	"strconv"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/dvdvideo"
)

func bindDVDCapabilities(
	titles []dvdvideo.Candidate,
	files map[controller.FileID]controller.InventoryFile,
) ([]contracts.Capability, error) {
	if len(titles) > 128 {
		return nil, fmt.Errorf("too many DVD title candidates")
	}
	capabilities := make([]contracts.Capability, 0, len(titles))
	for _, title := range titles {
		navigation, found := files[title.NavigationFileID]
		if !found || len(title.SourceFileIDs) == 0 || len(title.SourceFileIDs) > 1024 {
			return nil, fmt.Errorf("DVD title has incomplete source inventory")
		}
		details := title.Details
		if details.Number < 1 || details.Number > 128 || details.Angles != 1 ||
			details.TitleSet < 1 || details.TitleSet > 99 ||
			details.TitleInSet < 1 || details.TitleInSet > 99 ||
			details.DurationMS <= 0 || details.Chapters <= 0 {
			return nil, fmt.Errorf("DVD title has invalid navigation metadata")
		}
		tracks := make([]contracts.TrackElement, 0, len(details.Tracks))
		for _, track := range details.Tracks {
			if track.Codec == "" ||
				(track.Kind != "video" && track.Kind != "audio" && track.Kind != "subtitles") {
				return nil, fmt.Errorf("DVD title has an invalid track")
			}
			var language *string
			if track.Language != "" {
				language = &track.Language
			}
			tracks = append(tracks, contracts.TrackElement{
				Kind: contracts.TrackKind(track.Kind), Codec: track.Codec, Language: language,
			})
		}
		if len(tracks) == 0 || len(tracks) > 32 {
			return nil, fmt.Errorf("DVD title has an invalid track count")
		}
		identity := []string{
			string(contracts.CapabilityActionRemuxDVD), string(title.NavigationFileID),
			navigation.Fingerprint.Fingerprint(),
			strconv.Itoa(details.Number), strconv.Itoa(details.TitleSet),
			strconv.Itoa(details.TitleInSet), strconv.FormatInt(details.DurationMS, 10),
			strconv.Itoa(details.Chapters),
		}
		sourceIDs := make([]string, 0, len(title.SourceFileIDs))
		seen := make(map[controller.FileID]bool, len(title.SourceFileIDs))
		for _, fileID := range title.SourceFileIDs {
			file, found := files[fileID]
			if !found || seen[fileID] {
				return nil, fmt.Errorf("DVD title source is missing or duplicated")
			}
			seen[fileID] = true
			sourceIDs = append(sourceIDs, string(fileID))
			identity = append(identity, string(fileID), file.Fingerprint.Fingerprint())
		}
		if !seen[title.NavigationFileID] {
			return nil, fmt.Errorf("DVD navigation file is not bound to title sources")
		}
		navigationID := string(title.NavigationFileID)
		capabilities = append(capabilities, contracts.Capability{
			Action:           contracts.CapabilityActionRemuxDVD,
			CapabilityID:     opaqueID("capability", identity...),
			NavigationFileID: &navigationID, SourceFileIDS: sourceIDs,
			TitleNumber: ptr(int64(details.Number)), TitleSet: ptr(int64(details.TitleSet)),
			TitleInSet: ptr(int64(details.TitleInSet)), AngleCount: ptr(int64(details.Angles)),
			DurationMS: ptr(details.DurationMS), ChapterCount: ptr(int64(details.Chapters)),
			Tracks: tracks,
		})
	}
	return capabilities, nil
}

func ptr[T any](value T) *T { return &value }

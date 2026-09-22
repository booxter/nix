package decisionpolicy

import (
	"math"
	"path/filepath"
	"slices"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
)

type RemuxRejectionReason string

const (
	RemuxWrongDecision     RemuxRejectionReason = "wrong_decision"
	RemuxCaseMismatch      RemuxRejectionReason = "case_mismatch"
	RemuxCapabilityMissing RemuxRejectionReason = "capability_missing"
	RemuxPlaylistMismatch  RemuxRejectionReason = "playlist_mismatch"
	RemuxFileUnavailable   RemuxRejectionReason = "file_unavailable"
	RemuxRuntimeMissing    RemuxRejectionReason = "runtime_missing"
	RemuxRuntimeMismatch   RemuxRejectionReason = "runtime_mismatch"
)

type AuthorizedRemuxFile struct {
	FileID      controller.FileID
	Fingerprint controller.FileFingerprint
}

type AuthorizedRemux struct {
	CaseID             string
	CapabilityID       string
	Playlist           AuthorizedRemuxFile
	Clips              []AuthorizedRemuxFile
	SourceBytes        int64
	ExpectedDurationMS int64
	ExpectedChapters   int64
	ExpectedTracks     []mkvmerge.Track
}

type RemuxValidation struct {
	Authorized *AuthorizedRemux
	Rejections []RemuxRejectionReason
}

func (validation RemuxValidation) Accepted() bool {
	return validation.Authorized != nil && len(validation.Rejections) == 0
}

// ValidateRemux binds the model's playlist choice to a complete local disc
// snapshot and checks it against Radarr's movie runtime.
func ValidateRemux(
	assembly casebuilder.Assembly,
	decision contracts.RepairDecisionV3,
) RemuxValidation {
	if decision.Kind != contracts.ActionRemuxBluray || decision.RemuxBluray == nil ||
		string(decision.RemuxBluray.Action) != string(contracts.ActionRemuxBluray) {
		return rejectRemux(RemuxWrongDecision)
	}
	if decision.RemuxBluray.CaseID != assembly.Request.CaseID ||
		assembly.LocalSnapshot.CaseID != assembly.Request.CaseID {
		return rejectRemux(RemuxCaseMismatch)
	}
	capability, found := findCapability(
		assembly.Request.Capabilities, decision.RemuxBluray.CapabilityID,
	)
	if !found || capability.Action != contracts.CapabilityActionRemuxBluray ||
		capability.PlaylistFileID == nil || capability.DurationMS == nil ||
		capability.ChapterCount == nil || len(capability.ClipFileIDS) == 0 ||
		len(capability.Tracks) == 0 {
		return rejectRemux(RemuxCapabilityMissing)
	}
	var playlist *mkvmerge.Candidate
	for index := range assembly.LocalSnapshot.Observation.BluRayPlaylists {
		candidate := &assembly.LocalSnapshot.Observation.BluRayPlaylists[index]
		if string(candidate.PlaylistFileID) == *capability.PlaylistFileID {
			if playlist != nil {
				return rejectRemux(RemuxPlaylistMismatch)
			}
			playlist = candidate
		}
	}
	if playlist == nil || playlist.Details.DurationMS != *capability.DurationMS ||
		int64(playlist.Details.Chapters) != *capability.ChapterCount ||
		!slices.EqualFunc(playlist.Details.Tracks, capability.Tracks, remuxTrackMatches) ||
		len(playlist.ClipFileIDs) != len(capability.ClipFileIDS) ||
		!slices.EqualFunc(playlist.ClipFileIDs, capability.ClipFileIDS,
			func(fileID controller.FileID, offered string) bool { return string(fileID) == offered }) {
		return rejectRemux(RemuxPlaylistMismatch)
	}

	observation := assembly.LocalSnapshot.Observation
	if observation.Movie == nil || observation.Movie.RuntimeMinutes == nil ||
		*observation.Movie.RuntimeMinutes <= 0 {
		return rejectRemux(RemuxRuntimeMissing)
	}
	runtime := assessManualImportRuntime(
		playlist.Details.DurationMS, observation.Movie.RuntimeMinutes,
	)
	if runtime.DifferenceMS == nil || *runtime.DifferenceMS > *runtime.ToleranceMS {
		return rejectRemux(RemuxRuntimeMismatch)
	}
	files := indexFiles(observation.Inventory)
	paths := make(map[controller.FileID]string, len(observation.Inventory.Paths))
	for _, path := range observation.Inventory.Paths {
		paths[path.FileID] = path.AbsolutePath
	}
	playlistFile, ok := availableRemuxFile(files, paths, playlist.PlaylistFileID)
	if !ok || !mkvmerge.NumberedPlaylist(filepath.Base(paths[playlist.PlaylistFileID])) {
		return rejectRemux(RemuxFileUnavailable)
	}
	playlistPath := paths[playlist.PlaylistFileID]
	if filepath.Base(filepath.Dir(playlistPath)) != "PLAYLIST" ||
		filepath.Base(filepath.Dir(filepath.Dir(playlistPath))) != "BDMV" {
		return rejectRemux(RemuxPlaylistMismatch)
	}
	streamDirectory := filepath.Join(filepath.Dir(filepath.Dir(playlistPath)), "STREAM")
	authorized := &AuthorizedRemux{
		CaseID:             assembly.Request.CaseID,
		CapabilityID:       capability.CapabilityID,
		Playlist:           playlistFile,
		Clips:              make([]AuthorizedRemuxFile, 0, len(playlist.ClipFileIDs)),
		ExpectedDurationMS: playlist.Details.DurationMS,
		ExpectedChapters:   int64(playlist.Details.Chapters),
		ExpectedTracks:     append([]mkvmerge.Track(nil), playlist.Details.Tracks...),
	}
	for position, clipID := range playlist.ClipFileIDs {
		clip, ok := availableRemuxFile(files, paths, clipID)
		path := paths[clipID]
		if !ok || path != playlist.Details.ClipPaths[position] ||
			filepath.Dir(path) != streamDirectory ||
			!mkvmerge.NumberedClip(filepath.Base(path)) ||
			clip.Fingerprint.SizeBytes > math.MaxInt64-authorized.SourceBytes {
			return rejectRemux(RemuxFileUnavailable)
		}
		authorized.Clips = append(authorized.Clips, clip)
		authorized.SourceBytes += clip.Fingerprint.SizeBytes
	}
	return RemuxValidation{Authorized: authorized}
}

func availableRemuxFile(
	files map[controller.FileID]controller.InventoryFile,
	paths map[controller.FileID]string,
	fileID controller.FileID,
) (AuthorizedRemuxFile, bool) {
	file, found := files[fileID]
	path, hasPath := paths[fileID]
	if !found || !hasPath || !filepath.IsAbs(path) || filepath.Clean(path) != path ||
		file.Fingerprint.SizeBytes <= 0 {
		return AuthorizedRemuxFile{}, false
	}
	if file.DownloadFile != nil && (!file.DownloadFile.Selected ||
		file.DownloadFile.LengthBytes != file.Fingerprint.SizeBytes ||
		file.DownloadFile.BytesCompleted != file.Fingerprint.SizeBytes) {
		return AuthorizedRemuxFile{}, false
	}
	return AuthorizedRemuxFile{FileID: fileID, Fingerprint: file.Fingerprint}, true
}

func remuxTrackMatches(identified mkvmerge.Track, offered contracts.TrackElement) bool {
	if identified.Kind != string(offered.Kind) || identified.Codec != offered.Codec {
		return false
	}
	if offered.Language == nil {
		return identified.Language == ""
	}
	return identified.Language == *offered.Language
}

func rejectRemux(reason RemuxRejectionReason) RemuxValidation {
	return RemuxValidation{Rejections: []RemuxRejectionReason{reason}}
}

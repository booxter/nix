package decisionpolicy

import (
	"math"
	"path/filepath"
	"slices"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/dvdvideo"
)

type AuthorizedDVD struct {
	CaseID             string
	CapabilityID       string
	Navigation         AuthorizedRemuxFile
	Sources            []AuthorizedRemuxFile
	TitleNumber        int
	ExpectedDurationMS int64
	ExpectedChapters   int
	ExpectedTracks     []dvdvideo.Track
	SourceBytes        int64
}

type DVDValidation struct {
	Authorized *AuthorizedDVD
	Rejections []RemuxRejectionReason
}

func (validation DVDValidation) Accepted() bool {
	return validation.Authorized != nil && len(validation.Rejections) == 0
}

func rejectDVD(reason RemuxRejectionReason) DVDValidation {
	return DVDValidation{Rejections: []RemuxRejectionReason{reason}}
}

// ValidateDVD binds the chosen title to every file in its inventoried VIDEO_TS
// tree and checks its duration against Radarr's movie runtime.
func ValidateDVD(assembly casebuilder.Assembly, decision contracts.RepairDecisionV2) DVDValidation {
	if decision.Kind != contracts.ActionRemuxDVD || decision.RemuxDVD == nil ||
		string(decision.RemuxDVD.Action) != string(contracts.ActionRemuxDVD) {
		return rejectDVD(RemuxWrongDecision)
	}
	if decision.RemuxDVD.CaseID != assembly.Request.CaseID ||
		assembly.LocalSnapshot.CaseID != assembly.Request.CaseID {
		return rejectDVD(RemuxCaseMismatch)
	}
	capability, found := findCapability(assembly.Request.Capabilities, decision.RemuxDVD.CapabilityID)
	if !found || capability.Action != contracts.CapabilityActionRemuxDVD ||
		capability.NavigationFileID == nil || capability.TitleNumber == nil ||
		capability.TitleSet == nil || capability.TitleInSet == nil || capability.AngleCount == nil ||
		capability.DurationMS == nil || capability.ChapterCount == nil ||
		len(capability.SourceFileIDS) == 0 || len(capability.Tracks) == 0 {
		return rejectDVD(RemuxCapabilityMissing)
	}
	var title *dvdvideo.Candidate
	for index := range assembly.LocalSnapshot.Observation.DVDTitles {
		candidate := &assembly.LocalSnapshot.Observation.DVDTitles[index]
		if string(candidate.NavigationFileID) == *capability.NavigationFileID &&
			candidate.Details.Number == int(*capability.TitleNumber) {
			if title != nil {
				return rejectDVD(RemuxPlaylistMismatch)
			}
			title = candidate
		}
	}
	if title == nil || title.Details.DurationMS != *capability.DurationMS ||
		title.Details.Chapters != int(*capability.ChapterCount) ||
		title.Details.TitleSet != int(*capability.TitleSet) ||
		title.Details.TitleInSet != int(*capability.TitleInSet) ||
		title.Details.Angles != int(*capability.AngleCount) || title.Details.Angles != 1 ||
		len(title.Details.Tracks) != len(capability.Tracks) ||
		len(title.SourceFileIDs) != len(capability.SourceFileIDS) ||
		!slices.EqualFunc(title.SourceFileIDs, capability.SourceFileIDS,
			func(fileID controller.FileID, offered string) bool { return string(fileID) == offered }) {
		return rejectDVD(RemuxPlaylistMismatch)
	}
	for index, track := range title.Details.Tracks {
		offered := capability.Tracks[index]
		if track.Kind != string(offered.Kind) || track.Codec != offered.Codec ||
			(track.Language == "" && offered.Language != nil) ||
			(track.Language != "" && (offered.Language == nil || track.Language != *offered.Language)) {
			return rejectDVD(RemuxPlaylistMismatch)
		}
	}
	observation := assembly.LocalSnapshot.Observation
	if observation.Movie == nil || observation.Movie.RuntimeMinutes == nil ||
		*observation.Movie.RuntimeMinutes <= 0 {
		return rejectDVD(RemuxRuntimeMissing)
	}
	runtime := assessManualImportRuntime(title.Details.DurationMS, observation.Movie.RuntimeMinutes)
	if runtime.DifferenceMS == nil || *runtime.DifferenceMS > *runtime.ToleranceMS {
		return rejectDVD(RemuxRuntimeMismatch)
	}
	files := indexFiles(observation.Inventory)
	paths := make(map[controller.FileID]string, len(observation.Inventory.Paths))
	for _, path := range observation.Inventory.Paths {
		paths[path.FileID] = path.AbsolutePath
	}
	navigation, ok := availableRemuxFile(files, paths, title.NavigationFileID)
	if !ok {
		return rejectDVD(RemuxFileUnavailable)
	}
	navigationPath := paths[title.NavigationFileID]
	directory := filepath.Dir(navigationPath)
	if filepath.Base(navigationPath) != "VIDEO_TS.IFO" || filepath.Base(directory) != "VIDEO_TS" {
		return rejectDVD(RemuxPlaylistMismatch)
	}
	authorized := &AuthorizedDVD{
		CaseID: assembly.Request.CaseID, CapabilityID: capability.CapabilityID,
		Navigation: navigation, TitleNumber: title.Details.Number,
		ExpectedDurationMS: title.Details.DurationMS,
		ExpectedChapters:   title.Details.Chapters,
		ExpectedTracks:     append([]dvdvideo.Track(nil), title.Details.Tracks...),
		Sources:            make([]AuthorizedRemuxFile, 0, len(title.SourceFileIDs)),
	}
	for _, fileID := range title.SourceFileIDs {
		source, ok := availableRemuxFile(files, paths, fileID)
		if !ok || filepath.Dir(paths[fileID]) != directory ||
			source.Fingerprint.SizeBytes > math.MaxInt64-authorized.SourceBytes {
			return rejectDVD(RemuxFileUnavailable)
		}
		authorized.Sources = append(authorized.Sources, source)
		authorized.SourceBytes += source.Fingerprint.SizeBytes
	}
	if !slices.ContainsFunc(authorized.Sources, func(source AuthorizedRemuxFile) bool {
		return source.FileID == navigation.FileID
	}) {
		return rejectDVD(RemuxFileUnavailable)
	}
	return DVDValidation{Authorized: authorized}
}

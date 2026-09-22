package lidarrrepair

import (
	"fmt"
	"reflect"
	"sort"

	"github.com/booxter/nix-config/radarr-repair/lidarrcontracts"
	"golift.io/starr"
)

type AuthorizedTrack struct {
	ArtifactID              string
	ArtifactFingerprint     string
	TrackID                 int64
	Path                    string
	Quality                 *starr.Quality
	IndexerFlags            int
	DownloadID              string
	DisableReleaseSwitching bool
}

type AuthorizedImport struct {
	CaseID       string
	CapabilityID string
	QueueID      int64
	ArtistID     int64
	AlbumID      int64
	ReleaseID    int64
	Tracks       []AuthorizedTrack
}

func AuthorizeImport(
	planned Record,
	current Evidence,
) (AuthorizedImport, bool, error) {
	plannedCase, err := lidarrcontracts.DecodeCase(planned.Case)
	if err != nil {
		return AuthorizedImport{}, false, fmt.Errorf("decode planned Lidarr case: %w", err)
	}
	decision, err := lidarrcontracts.DecodeDecision(planned.Decision)
	if err != nil {
		return AuthorizedImport{}, false, fmt.Errorf("decode planned Lidarr decision: %w", err)
	}
	if decision.Kind == lidarrcontracts.ActionNoRepair {
		return AuthorizedImport{}, false, nil
	}
	if planned.QueueID != current.Queue.ID || planned.QueueID != current.Case.Queue.QueueID ||
		planned.ArchivePath != current.ArchivePath ||
		planned.ArchiveFingerprint != current.ArchiveFingerprint ||
		planned.WorkspaceRoot != current.WorkspaceRoot {
		return AuthorizedImport{}, false, fmt.Errorf("current Lidarr evidence does not match the planned case")
	}
	if !reflect.DeepEqual(planned.Bindings, current.Bindings) {
		return AuthorizedImport{}, false, fmt.Errorf("current Lidarr import bindings changed after planning")
	}
	validate := ValidateDecision
	if current.Recovered {
		validate = validateDecisionSelection
	} else if plannedCase.CaseID != current.Case.CaseID {
		return AuthorizedImport{}, false, fmt.Errorf("current Lidarr evidence does not match the planned case")
	}
	if err := validate(current.Case, decision); err != nil {
		return AuthorizedImport{}, false, fmt.Errorf("revalidate planned Lidarr repair: %w", err)
	}
	selected := decision.ImportMissingTracks
	if selected == nil {
		return AuthorizedImport{}, false, fmt.Errorf("Lidarr import decision is missing")
	}

	bindings := make(map[string]ImportBinding, len(current.Bindings))
	for _, binding := range current.Bindings {
		bindings[binding.ArtifactID] = binding
	}
	fingerprints := make(map[string]string, len(current.Case.Artifacts))
	for _, artifact := range current.Case.Artifacts {
		fingerprints[artifact.ArtifactID] = artifact.Fingerprint
	}
	albumHasFiles := false
	for _, track := range current.Case.Tracks {
		albumHasFiles = albumHasFiles || track.HasFile
	}

	authorized := AuthorizedImport{
		CaseID: plannedCase.CaseID, CapabilityID: selected.CapabilityID,
		QueueID: current.Queue.ID, ArtistID: current.Case.Album.ArtistID,
		AlbumID: selected.AlbumID, ReleaseID: selected.ReleaseID,
		Tracks: make([]AuthorizedTrack, len(selected.Mappings)),
	}
	for index, mapping := range selected.Mappings {
		binding, found := bindings[mapping.ArtifactID]
		fingerprint, fingerprintFound := fingerprints[mapping.ArtifactID]
		if !found || !fingerprintFound || binding.Quality == nil ||
			binding.DownloadID != current.Queue.DownloadID {
			return AuthorizedImport{}, false, fmt.Errorf(
				"Lidarr import mapping %d has no complete current binding",
				index,
			)
		}
		authorized.Tracks[index] = AuthorizedTrack{
			ArtifactID: mapping.ArtifactID, ArtifactFingerprint: fingerprint,
			TrackID: mapping.TrackID, Path: binding.Path, Quality: binding.Quality,
			IndexerFlags: binding.IndexerFlags, DownloadID: binding.DownloadID,
			DisableReleaseSwitching: albumHasFiles,
		}
	}
	sort.Slice(authorized.Tracks, func(left, right int) bool {
		return authorized.Tracks[left].TrackID < authorized.Tracks[right].TrackID
	})
	return authorized, true, nil
}

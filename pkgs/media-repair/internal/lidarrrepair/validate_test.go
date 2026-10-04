package lidarrrepair

import (
	"testing"

	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

func TestValidateDecisionAllowsPartialMapping(t *testing.T) {
	repairCase, decision := partialDecision(t)
	if err := ValidateDecision(repairCase, decision); err != nil {
		t.Fatal(err)
	}
}

func partialDecision(t *testing.T) (lidarrcontracts.Case, lidarrcontracts.Decision) {
	t.Helper()
	repairCase := lidarrcontracts.Case{
		SchemaVersion: lidarrcontracts.SchemaVersion,
		Capabilities: []lidarrcontracts.Capability{{
			Action: string(lidarrcontracts.ActionImportMissingTracks), CapabilityID: "capability:one",
			AlbumID: 3, ArtifactIDs: []string{"artifact:one", "artifact:two"}, ReleaseID: 4,
			TrackIDs: []int64{5, 6},
		}},
		Artifacts: []lidarrcontracts.Artifact{
			{ArtifactID: "artifact:one"},
			{ArtifactID: "artifact:two"},
		},
	}
	caseID, err := lidarrcontracts.CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	repairCase.CaseID = caseID
	return repairCase, lidarrcontracts.Decision{
		Kind: lidarrcontracts.ActionImportMissingTracks,
		ImportMissingTracks: &lidarrcontracts.ImportMissingTracksDecision{
			SchemaVersion: lidarrcontracts.SchemaVersion, CaseID: caseID,
			Action: string(lidarrcontracts.ActionImportMissingTracks), CapabilityID: "capability:one",
			AlbumID: 3, ReleaseID: 4,
			Mappings: []lidarrcontracts.TrackMapping{{ArtifactID: "artifact:one", TrackID: 5}},
		},
	}
}

package lidarrrepair

import (
	"strings"
	"testing"

	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

func TestValidateDecisionAllowsPartialV3Mapping(t *testing.T) {
	repairCase, decision := partialDecision(t, lidarrcontracts.SchemaVersion)
	if err := ValidateDecision(repairCase, decision); err != nil {
		t.Fatal(err)
	}
}

func TestValidateDecisionRequiresCompleteV2Mapping(t *testing.T) {
	repairCase, decision := partialDecision(t, lidarrcontracts.LidarrRepairV2)
	err := ValidateDecision(repairCase, decision)
	if err == nil || !strings.Contains(err.Error(), "every missing track") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func partialDecision(
	t *testing.T,
	schemaVersion string,
) (lidarrcontracts.Case, lidarrcontracts.Decision) {
	t.Helper()
	repairCase := lidarrcontracts.Case{
		SchemaVersion: schemaVersion,
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
			SchemaVersion: schemaVersion, CaseID: caseID,
			Action: string(lidarrcontracts.ActionImportMissingTracks), CapabilityID: "capability:one",
			AlbumID: 3, ReleaseID: 4,
			Mappings: []lidarrcontracts.TrackMapping{{ArtifactID: "artifact:one", TrackID: 5}},
		},
	}
}

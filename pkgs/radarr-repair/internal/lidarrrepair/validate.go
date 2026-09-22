package lidarrrepair

import (
	"fmt"

	"github.com/booxter/nix-config/radarr-repair/lidarrcontracts"
)

func ValidateDecision(
	repairCase lidarrcontracts.Case,
	decision lidarrcontracts.Decision,
) error {
	if decision.CaseID() != repairCase.CaseID {
		return fmt.Errorf("Lidarr decision case ID does not match")
	}
	if decision.Kind == lidarrcontracts.ActionNoRepair && decision.NoRepair != nil {
		return validateEvidenceReferences(repairCase, decision.NoRepair.EvidenceRefs)
	}
	if decision.Kind != lidarrcontracts.ActionImportTrackSet || decision.ImportTrackSet == nil {
		return fmt.Errorf("Lidarr decision action is inconsistent")
	}
	selected := decision.ImportTrackSet
	if err := validateEvidenceReferences(repairCase, selected.EvidenceRefs); err != nil {
		return err
	}
	var capability *lidarrcontracts.Capability
	for index := range repairCase.Capabilities {
		if repairCase.Capabilities[index].CapabilityID == selected.CapabilityID {
			capability = &repairCase.Capabilities[index]
			break
		}
	}
	if capability == nil || capability.Action != string(lidarrcontracts.ActionImportTrackSet) {
		return fmt.Errorf("Lidarr decision selects an unknown capability")
	}
	if selected.AlbumID != capability.AlbumID || !contains(capability.ReleaseIDs, selected.ReleaseID) {
		return fmt.Errorf("Lidarr decision selects an album or release outside its capability")
	}
	artifacts := make(map[string]struct{}, len(selected.Mappings))
	tracks := make(map[int64]struct{}, len(selected.Mappings))
	for _, mapping := range selected.Mappings {
		if !contains(capability.ArtifactIDs, mapping.ArtifactID) ||
			!contains(capability.TrackIDs, mapping.TrackID) {
			return fmt.Errorf("Lidarr decision mapping is outside its capability")
		}
		if _, duplicate := artifacts[mapping.ArtifactID]; duplicate {
			return fmt.Errorf("Lidarr decision maps an artifact more than once")
		}
		if _, duplicate := tracks[mapping.TrackID]; duplicate {
			return fmt.Errorf("Lidarr decision maps a track more than once")
		}
		artifacts[mapping.ArtifactID] = struct{}{}
		tracks[mapping.TrackID] = struct{}{}
	}
	if len(artifacts) != len(capability.ArtifactIDs) || len(tracks) != len(capability.TrackIDs) {
		return fmt.Errorf("Lidarr decision does not map the complete capability")
	}
	return nil
}

func validateEvidenceReferences(repairCase lidarrcontracts.Case, references []string) error {
	allowed := make(map[string]struct{}, len(repairCase.Artifacts)+len(repairCase.Capabilities))
	for _, artifact := range repairCase.Artifacts {
		allowed[artifact.ArtifactID] = struct{}{}
	}
	for _, capability := range repairCase.Capabilities {
		allowed[capability.CapabilityID] = struct{}{}
	}
	for _, reference := range references {
		if _, found := allowed[reference]; !found {
			return fmt.Errorf("Lidarr decision references unknown evidence")
		}
	}
	return nil
}

func contains[T comparable](values []T, wanted T) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

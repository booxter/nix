package decisionpolicy

import (
	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
)

type JoinRejectionReason string

const (
	JoinWrongDecisionAction     JoinRejectionReason = "wrong_decision_action"
	JoinCaseMismatch            JoinRejectionReason = "case_mismatch"
	JoinCapabilityNotFound      JoinRejectionReason = "capability_not_found"
	JoinCapabilityWrongAction   JoinRejectionReason = "capability_wrong_action"
	JoinTooFewSelectedFiles     JoinRejectionReason = "too_few_selected_files"
	JoinDuplicateSelectedFile   JoinRejectionReason = "duplicate_selected_file"
	JoinFileNotOffered          JoinRejectionReason = "file_not_offered"
	JoinFileNotInSnapshot       JoinRejectionReason = "file_not_in_snapshot"
	JoinFileNotActionable       JoinRejectionReason = "file_not_actionable"
	JoinProbeUnavailable        JoinRejectionReason = "probe_unavailable"
	JoinTechnicalChecksRejected JoinRejectionReason = "technical_checks_rejected"
)

type AuthorizedJoinPart struct {
	FileID      controller.FileID
	Fingerprint controller.FileFingerprint
}

type AuthorizedJoin struct {
	CaseID               string
	CapabilityID         string
	OrderedParts         []AuthorizedJoinPart
	SourceBytes          int64
	ExpectedDurationMS   int64
	DurationToleranceMS  int64
	OutputContainer      controller.OutputContainer
	ExpectedStreamLayout controller.StreamLayout
}

func ValidateJoin(
	assembly casebuilder.Assembly,
	decision contracts.RepairDecisionV3,
) (*AuthorizedJoin, JoinRejectionReason) {
	if decision.Kind != contracts.ActionJoinParts || decision.JoinParts == nil ||
		string(decision.JoinParts.Action) != string(contracts.ActionJoinParts) {
		return nil, JoinWrongDecisionAction
	}
	join := decision.JoinParts
	if join.CaseID != assembly.Request.CaseID ||
		assembly.LocalSnapshot.CaseID != assembly.Request.CaseID {
		return nil, JoinCaseMismatch
	}

	capability, found := findCapability(assembly.Request.Capabilities, join.CapabilityID)
	if !found {
		return nil, JoinCapabilityNotFound
	}
	if capability.Action != contracts.CapabilityActionJoinParts {
		return nil, JoinCapabilityWrongAction
	}
	if len(join.OrderedFileIDS) < 2 {
		return nil, JoinTooFewSelectedFiles
	}

	offered := make(map[string]struct{}, len(capability.CandidateFileIDS))
	for _, fileID := range capability.CandidateFileIDS {
		offered[fileID] = struct{}{}
	}
	files := indexFiles(assembly.LocalSnapshot.Observation.Inventory)
	probes := indexProbes(assembly.LocalSnapshot.Observation.Probes)
	seen := make(map[string]struct{}, len(join.OrderedFileIDS))
	parts := make([]controller.JoinPartEvidence, 0, len(join.OrderedFileIDS))
	for _, selectedID := range join.OrderedFileIDS {
		fileID := controller.FileID(selectedID)
		if _, duplicate := seen[selectedID]; duplicate {
			return nil, JoinDuplicateSelectedFile
		}
		seen[selectedID] = struct{}{}
		if _, allowed := offered[selectedID]; !allowed {
			return nil, JoinFileNotOffered
		}
		file, found := files[fileID]
		if !found {
			return nil, JoinFileNotInSnapshot
		}
		assessment := controller.ClassifyMediaFiles(
			controller.FileInventory{Files: []controller.InventoryFile{file}},
		)[0]
		if !assessment.ProbeCandidate() ||
			!controller.SupportsJoinPartsPath(file.PathComponents) {
			return nil, JoinFileNotActionable
		}
		probe, found := probes[fileID]
		if !found || probe.Status != controller.MediaProbeSucceeded || probe.Evidence == nil {
			return nil, JoinProbeUnavailable
		}
		parts = append(parts, controller.JoinPartEvidence{
			FileID:      fileID,
			Extension:   assessment.Extension,
			Fingerprint: file.Fingerprint,
			Probe:       probe.Evidence,
		})
	}
	feasibility := controller.AssessJoinFeasibility(parts)
	if !feasibility.Eligible() {
		return nil, JoinTechnicalChecksRejected
	}

	orderedParts := make([]AuthorizedJoinPart, len(parts))
	for position, part := range parts {
		orderedParts[position] = AuthorizedJoinPart{
			FileID:      part.FileID,
			Fingerprint: part.Fingerprint,
		}
	}
	return &AuthorizedJoin{
		CaseID:               assembly.Request.CaseID,
		CapabilityID:         capability.CapabilityID,
		OrderedParts:         orderedParts,
		SourceBytes:          *feasibility.SourceBytes,
		ExpectedDurationMS:   *feasibility.Duration.ExpectedMS,
		DurationToleranceMS:  *feasibility.Duration.ToleranceMS,
		OutputContainer:      *feasibility.OutputContainer.Container,
		ExpectedStreamLayout: feasibility.Streams.Layout.Clone(),
	}, ""
}

func findCapability(capabilities []contracts.Capability, capabilityID string) (contracts.Capability, bool) {
	for _, capability := range capabilities {
		if capability.CapabilityID == capabilityID {
			return capability, true
		}
	}
	return contracts.Capability{}, false
}

func indexFiles(inventory controller.FileInventory) map[controller.FileID]controller.InventoryFile {
	files := make(map[controller.FileID]controller.InventoryFile, len(inventory.Files))
	for _, file := range inventory.Files {
		files[file.ID] = file
	}
	return files
}

func indexProbes(probes []controller.FileProbe) map[controller.FileID]controller.MediaProbeOutcome {
	indexed := make(map[controller.FileID]controller.MediaProbeOutcome, len(probes))
	for _, probe := range probes {
		indexed[probe.FileID] = probe.Outcome
	}
	return indexed
}

package decisionpolicy

import (
	"slices"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

func TestValidateJoinAuthorizesSelectedSubsetInPlannerOrder(t *testing.T) {
	t.Parallel()

	assembly := joinAssembly()
	decision := joinDecision(assembly.Request.CaseID, "file:second", "file:first")

	validation := ValidateJoin(assembly, decision)
	if !validation.Accepted() || validation.Authorized == nil {
		t.Fatalf("validation = %#v", validation)
	}
	authorized := validation.Authorized
	wantOrder := []controller.FileID{"file:second", "file:first"}
	gotOrder := make([]controller.FileID, len(authorized.OrderedParts))
	for position, part := range authorized.OrderedParts {
		gotOrder[position] = part.FileID
	}
	if !slices.Equal(gotOrder, wantOrder) {
		t.Fatalf("ordered files = %v, want %v", gotOrder, wantOrder)
	}
	if authorized.SourceBytes != 300 || authorized.ExpectedDurationMS != 30_000 ||
		authorized.DurationToleranceMS != 1_000 ||
		authorized.OutputContainer != controller.OutputContainerMKV {
		t.Fatalf("authorized join = %#v", authorized)
	}
	if len(authorized.ExpectedStreamLayout.Streams) != 1 ||
		authorized.ExpectedStreamLayout.Streams[0].Kind != controller.ProbeStreamVideo ||
		authorized.ExpectedStreamLayout.Streams[0].CodecName != "h264" {
		t.Fatalf("expected stream layout = %#v", authorized.ExpectedStreamLayout)
	}
}

func TestValidateJoinRejectsSelectionsOutsideGrantedAuthority(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*casebuilder.Assembly, *contracts.RepairDecisionV2)
		reason JoinRejectionReason
	}{
		{
			name: "different case",
			mutate: func(_ *casebuilder.Assembly, decision *contracts.RepairDecisionV2) {
				decision.JoinParts.CaseID = "sha256:different"
			},
			reason: JoinCaseMismatch,
		},
		{
			name: "unknown capability",
			mutate: func(_ *casebuilder.Assembly, decision *contracts.RepairDecisionV2) {
				decision.JoinParts.CapabilityID = "capability:unknown"
			},
			reason: JoinCapabilityNotFound,
		},
		{
			name: "capability for another action",
			mutate: func(assembly *casebuilder.Assembly, _ *contracts.RepairDecisionV2) {
				assembly.Request.Capabilities[0].Action = contracts.CapabilityActionManualImportFile
			},
			reason: JoinCapabilityWrongAction,
		},
		{
			name: "one selected file",
			mutate: func(_ *casebuilder.Assembly, decision *contracts.RepairDecisionV2) {
				decision.JoinParts.OrderedFileIDS = []string{"file:first"}
			},
			reason: JoinTooFewSelectedFiles,
		},
		{
			name: "duplicate selected file",
			mutate: func(_ *casebuilder.Assembly, decision *contracts.RepairDecisionV2) {
				decision.JoinParts.OrderedFileIDS = []string{"file:first", "file:first"}
			},
			reason: JoinDuplicateSelectedFile,
		},
		{
			name: "file outside pool",
			mutate: func(assembly *casebuilder.Assembly, _ *contracts.RepairDecisionV2) {
				assembly.Request.Capabilities[0].CandidateFileIDS = []string{"file:first"}
			},
			reason: JoinFileNotOffered,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			assembly := joinAssembly()
			decision := joinDecision(assembly.Request.CaseID, "file:first", "file:second")
			test.mutate(&assembly, &decision)

			validation := ValidateJoin(assembly, decision)
			assertRejected(t, validation, test.reason)
		})
	}
}

func TestValidateJoinRequiresSelectedLocalEvidence(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*casebuilder.Assembly)
		reason JoinRejectionReason
	}{
		{
			name: "missing inventory file",
			mutate: func(assembly *casebuilder.Assembly) {
				assembly.LocalSnapshot.Observation.Inventory.Files =
					assembly.LocalSnapshot.Observation.Inventory.Files[:1]
			},
			reason: JoinFileNotInSnapshot,
		},
		{
			name: "file no longer actionable in snapshot",
			mutate: func(assembly *casebuilder.Assembly) {
				assembly.LocalSnapshot.Observation.Inventory.Files[1].DownloadFile.Selected = false
			},
			reason: JoinFileNotActionable,
		},
		{
			name: "probe unavailable",
			mutate: func(assembly *casebuilder.Assembly) {
				assembly.LocalSnapshot.Observation.Probes[1].Outcome =
					controller.FailedMediaProbe(controller.MediaProbeTimeout)
			},
			reason: JoinProbeUnavailable,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			assembly := joinAssembly()
			test.mutate(&assembly)
			validation := ValidateJoin(
				assembly,
				joinDecision(assembly.Request.CaseID, "file:first", "file:second"),
			)
			assertRejected(t, validation, test.reason)
		})
	}
}

func TestValidateJoinRejectsTechnicallyIncompatibleSelection(t *testing.T) {
	t.Parallel()

	assembly := joinAssembly()
	assembly.LocalSnapshot.Observation.Probes[1].Outcome = controller.SuccessfulMediaProbe(
		joinProbe(20_000, 200, "hevc"),
	)
	validation := ValidateJoin(
		assembly,
		joinDecision(assembly.Request.CaseID, "file:first", "file:second"),
	)

	assertRejected(t, validation, JoinTechnicalChecksRejected)
	if validation.Feasibility == nil ||
		validation.Feasibility.Streams.Compatibility != controller.StreamsIncompatible {
		t.Fatalf("feasibility = %#v", validation.Feasibility)
	}
}

func TestValidateJoinRejectsAnotherDecisionVariant(t *testing.T) {
	t.Parallel()

	validation := ValidateJoin(joinAssembly(), contracts.RepairDecisionV2{
		Kind: contracts.ActionNoRepair,
		NoRepair: &contracts.NoRepairDecision{
			Action: contracts.NoRepair,
		},
	})
	assertRejected(t, validation, JoinWrongDecisionAction)
}

func assertRejected(t *testing.T, validation JoinValidation, reason JoinRejectionReason) {
	t.Helper()
	if validation.Accepted() || validation.Authorized != nil {
		t.Fatalf("decision was authorized: %#v", validation)
	}
	for _, rejection := range validation.Rejections {
		if rejection.Reason == reason {
			return
		}
	}
	t.Fatalf("rejections = %#v, want %q", validation.Rejections, reason)
}

func joinAssembly() casebuilder.Assembly {
	const caseID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	files := []controller.InventoryFile{
		joinInventoryFile("file:first", "part-1.mkv", 100),
		joinInventoryFile("file:second", "part-2.mkv", 200),
		joinInventoryFile("file:unselected", "bonus.mkv", 300),
	}
	return casebuilder.Assembly{
		Request: contracts.RepairCaseV2{
			CaseID: caseID,
			Capabilities: []contracts.Capability{{
				Action:       contracts.CapabilityActionJoinParts,
				CapabilityID: "capability:join",
				CandidateFileIDS: []string{
					"file:first", "file:second", "file:unselected",
				},
			}},
		},
		LocalSnapshot: casebuilder.LocalSnapshot{
			CaseID: caseID,
			Observation: casebuilder.Observation{
				Inventory: controller.FileInventory{Files: files},
				Probes: []casebuilder.FileProbe{
					{
						FileID: "file:first",
						Outcome: controller.SuccessfulMediaProbe(
							joinProbe(10_000, 100, "h264"),
						),
					},
					{
						FileID: "file:second",
						Outcome: controller.SuccessfulMediaProbe(
							joinProbe(20_000, 200, "h264"),
						),
					},
					{
						FileID: "file:unselected",
						Outcome: controller.SuccessfulMediaProbe(
							joinProbe(30_000, 300, "hevc"),
						),
					},
				},
			},
		},
	}
}

func joinDecision(caseID string, orderedFileIDs ...string) contracts.RepairDecisionV2 {
	return contracts.RepairDecisionV2{
		Kind: contracts.ActionJoinParts,
		JoinParts: &contracts.JoinDecision{
			Action:         contracts.JoinDecisionAction(contracts.ActionJoinParts),
			CaseID:         caseID,
			CapabilityID:   "capability:join",
			OrderedFileIDS: orderedFileIDs,
		},
	}
}

func joinInventoryFile(id controller.FileID, name string, size int64) controller.InventoryFile {
	return controller.InventoryFile{
		ID:             id,
		PathComponents: []string{name},
		Fingerprint:    controller.FileFingerprint{SizeBytes: size},
		DownloadFile: &controller.DownloadFileReference{
			LengthBytes: size, BytesCompleted: size, Selected: true,
		},
	}
}

func joinProbe(durationMS int64, size int64, codec string) controller.ProbeEvidence {
	kind := controller.ProbeStreamVideo
	timeBase := controller.Rational{Numerator: 1, Denominator: 1_000}
	frameRate := controller.Rational{Numerator: 24, Denominator: 1}
	width := int64(1_920)
	height := int64(1_080)
	pixelFormat := "yuv420p"
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names: []string{"matroska"}, DurationMS: &durationMS, SizeBytes: &size,
		},
		Streams: []controller.ProbeStream{{
			Index:       0,
			Kind:        &kind,
			CodecName:   &codec,
			TimeBase:    &timeBase,
			DurationMS:  &durationMS,
			Width:       &width,
			Height:      &height,
			PixelFormat: &pixelFormat,
			AverageRate: &frameRate,
		}},
	}
}

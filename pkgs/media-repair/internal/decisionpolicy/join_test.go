package decisionpolicy

import (
	"slices"
	"testing"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
)

func TestValidateJoinAuthorizesSelectedSubsetInPlannerOrder(t *testing.T) {
	t.Parallel()

	assembly := joinAssembly()
	decision := joinDecision(assembly.Request.CaseID, "file:second", "file:first")

	authorized, reason := ValidateJoin(assembly, decision)
	if reason != "" || authorized == nil {
		t.Fatalf("authorization = %#v, reason = %q", authorized, reason)
	}
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
		mutate func(*casebuilder.Assembly, *contracts.RepairDecisionV3)
		reason JoinRejectionReason
	}{
		{
			name: "different case",
			mutate: func(_ *casebuilder.Assembly, decision *contracts.RepairDecisionV3) {
				decision.JoinParts.CaseID = "sha256:different"
			},
			reason: JoinCaseMismatch,
		},
		{
			name: "unknown capability",
			mutate: func(_ *casebuilder.Assembly, decision *contracts.RepairDecisionV3) {
				decision.JoinParts.CapabilityID = "capability:unknown"
			},
			reason: JoinCapabilityNotFound,
		},
		{
			name: "capability for another action",
			mutate: func(assembly *casebuilder.Assembly, _ *contracts.RepairDecisionV3) {
				assembly.Request.Capabilities[0].Action = contracts.CapabilityActionManualImportFile
			},
			reason: JoinCapabilityWrongAction,
		},
		{
			name: "one selected file",
			mutate: func(_ *casebuilder.Assembly, decision *contracts.RepairDecisionV3) {
				decision.JoinParts.OrderedFileIDS = []string{"file:first"}
			},
			reason: JoinTooFewSelectedFiles,
		},
		{
			name: "duplicate selected file",
			mutate: func(_ *casebuilder.Assembly, decision *contracts.RepairDecisionV3) {
				decision.JoinParts.OrderedFileIDS = []string{"file:first", "file:first"}
			},
			reason: JoinDuplicateSelectedFile,
		},
		{
			name: "file outside pool",
			mutate: func(assembly *casebuilder.Assembly, _ *contracts.RepairDecisionV3) {
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

			authorized, reason := ValidateJoin(assembly, decision)
			assertRejected(t, authorized, reason, test.reason)
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
			authorized, reason := ValidateJoin(
				assembly,
				joinDecision(assembly.Request.CaseID, "file:first", "file:second"),
			)
			assertRejected(t, authorized, reason, test.reason)
		})
	}
}

func TestValidateJoinRejectsTechnicallyIncompatibleSelection(t *testing.T) {
	t.Parallel()

	assembly := joinAssembly()
	assembly.LocalSnapshot.Observation.Probes[1].Outcome = controller.SuccessfulMediaProbe(
		joinProbe(20_000, 200, "hevc"),
	)
	authorized, reason := ValidateJoin(
		assembly,
		joinDecision(assembly.Request.CaseID, "file:first", "file:second"),
	)

	assertRejected(t, authorized, reason, JoinTechnicalChecksRejected)
}

func TestValidateJoinRejectsAnotherDecisionVariant(t *testing.T) {
	t.Parallel()

	authorized, reason := ValidateJoin(joinAssembly(), contracts.RepairDecisionV3{
		Kind: contracts.ActionNoRepair,
		NoRepair: &contracts.NoRepairDecision{
			Action: contracts.NoRepair,
		},
	})
	assertRejected(t, authorized, reason, JoinWrongDecisionAction)
}

func TestValidateJoinReportsFirstRejection(t *testing.T) {
	assembly := joinAssembly()
	decision := joinDecision("different", "missing", "missing")
	decision.JoinParts.CapabilityID = "missing"
	authorized, reason := ValidateJoin(assembly, decision)
	assertRejected(t, authorized, reason, JoinCaseMismatch)
}

func assertRejected(t *testing.T, authorized *AuthorizedJoin, reason, want JoinRejectionReason) {
	t.Helper()
	if authorized != nil || reason != want {
		t.Fatalf("authorization = %#v, reason = %q, want %q", authorized, reason, want)
	}
}

func joinAssembly() casebuilder.Assembly {
	const caseID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	files := []controller.InventoryFile{
		joinInventoryFile("file:first", "part-1.mkv", 100),
		joinInventoryFile("file:second", "part-2.mkv", 200),
		joinInventoryFile("file:unselected", "bonus.mkv", 300),
	}
	return casebuilder.Assembly{
		Request: contracts.RepairCaseV3{
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
				Probes: []controller.FileProbe{
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

func joinDecision(caseID string, orderedFileIDs ...string) contracts.RepairDecisionV3 {
	return contracts.RepairDecisionV3{
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

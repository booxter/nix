package contracts

import (
	"reflect"
	"slices"
	"testing"
	"time"
)

func TestCalculateCaseIDMatchesExample(t *testing.T) {
	t.Parallel()

	repairCase := exampleCase(t)
	caseID, err := CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	if caseID != repairCase.CaseID {
		t.Fatalf("case ID = %q, want %q", caseID, repairCase.CaseID)
	}
}

func TestCaseIdentityExcludesObservationFields(t *testing.T) {
	t.Parallel()

	repairCase := exampleCase(t)
	want, err := CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	repairCase.CaseID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	repairCase.ObservedAt = repairCase.ObservedAt.Add(24 * time.Hour)
	got, err := CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("case ID changed from %q to %q", want, got)
	}
}

func TestCaseIdentityChangesWithPlanningEvidence(t *testing.T) {
	t.Parallel()

	repairCase := exampleCase(t)
	before, err := CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	repairCase.Files[0].PathComponents[1] = "Example.Movie.2024.Part1.mkv"
	after, err := CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	if after == before {
		t.Fatal("case ID did not change with planning evidence")
	}
}

func TestCaseIdentityChangesWithFileSize(t *testing.T) {
	t.Parallel()

	repairCase := exampleCase(t)
	before, err := CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	repairCase.Files[0].SizeBytes++
	after, err := CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	if after == before {
		t.Fatal("case ID did not change with file size")
	}
}

func TestCaseIdentityCanonicalizesJSONStrings(t *testing.T) {
	t.Parallel()

	repairCase := exampleCase(t)
	repairCase.Radarr.Movie.Title = "A < B & Caf\u00e9"
	caseID, err := CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	const want = "sha256:9be41b25237363eaedf1a49e3c0ef087d778f1b0f9b5731258ac40109685ece0"
	if caseID != want {
		t.Fatalf("case ID = %q, want %q", caseID, want)
	}
}

func TestEncodeCaseValidatesIdentityAndSchema(t *testing.T) {
	t.Parallel()

	repairCase := exampleCase(t)
	data, err := EncodeCase(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeCase(data)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.CaseID != repairCase.CaseID {
		t.Fatalf("encoded case ID = %q", decoded.CaseID)
	}

	repairCase.CaseID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if _, err := EncodeCase(repairCase); err == nil {
		t.Fatal("incorrect case ID was encoded")
	}

	repairCase = exampleCase(t)
	repairCase.Files = nil
	repairCase.CaseID, err = CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := EncodeCase(repairCase); err == nil {
		t.Fatal("schema-invalid case was encoded")
	}
}

func TestEncodeDecisionRoundTripsExamples(t *testing.T) {
	t.Parallel()

	for _, path := range []string{
		"v3/examples/repair-decision-no-repair.json",
		"v3/examples/repair-decision-join.json",
		"v3/examples/repair-decision-manual-import.json",
		"v3/examples/repair-decision-remux-bluray.json",
	} {
		path := path
		t.Run(path, func(t *testing.T) {
			t.Parallel()
			decision, err := DecodeDecision(readFixture(t, path))
			if err != nil {
				t.Fatal(err)
			}
			var joinOrder []string
			if decision.Kind == ActionJoinParts {
				slices.Reverse(decision.JoinParts.OrderedFileIDS)
				joinOrder = slices.Clone(decision.JoinParts.OrderedFileIDS)
			}
			encoded, err := EncodeDecision(decision)
			if err != nil {
				t.Fatal(err)
			}
			roundTripped, err := DecodeDecision(encoded)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(roundTripped, decision) {
				t.Fatalf("round trip = %#v, want %#v", roundTripped, decision)
			}
			if joinOrder != nil && !slices.Equal(roundTripped.JoinParts.OrderedFileIDS, joinOrder) {
				t.Fatalf("join order = %v, want %v", roundTripped.JoinParts.OrderedFileIDS, joinOrder)
			}
		})
	}
}

func TestEncodeDecisionRejectsInconsistentUnion(t *testing.T) {
	t.Parallel()

	valid, err := DecodeDecision(readFixture(t, "v3/examples/repair-decision-no-repair.json"))
	if err != nil {
		t.Fatal(err)
	}
	for name, decision := range map[string]RepairDecisionV3{
		"empty": {},
		"wrong kind": {
			Kind:     ActionJoinParts,
			NoRepair: valid.NoRepair,
		},
		"two actions": {
			Kind:             ActionNoRepair,
			NoRepair:         valid.NoRepair,
			ManualImportFile: &ManualImportFileDecision{},
		},
	} {
		decision := decision
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if _, err := EncodeDecision(decision); err == nil {
				t.Fatal("inconsistent decision encoded successfully")
			}
		})
	}
}

func TestDVDDecisionKeepsTitleOrder(t *testing.T) {
	t.Parallel()
	decision := RepairDecisionV3{
		Kind: ActionRemuxDVD,
		RemuxDVD: &RemuxDVDDecision{
			Action: "remux_dvd_v2", SchemaVersion: RadarrRepairV3,
			CaseID:       "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			EvidenceRefs: []string{"capability:disc1"}, Explanation: "Remux the movie titles.",
		},
	}

	order := []string{"capability:disc2", "capability:disc1"}
	decision.RemuxDVD.OrderedTitleIDS = slices.Clone(order)
	encoded, err := EncodeDecision(decision)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeDecision(encoded)
	if err != nil || !slices.Equal(decoded.RemuxDVD.OrderedTitleIDS, order) {
		t.Fatalf("DVD selection changed on round trip: %+v, %v", decoded, err)
	}
	if !reflect.DeepEqual(decoded, decision) {
		t.Fatalf("DVD decision round trip = %#v, want %#v", decoded, decision)
	}
	decision.RemuxDVD.OrderedTitleIDS = []string{"capability:disc1", "capability:disc1"}
	if _, err := EncodeDecision(decision); err == nil {
		t.Fatal("encoded a repeated title")
	}
}

func exampleCase(t *testing.T) RepairCaseV3 {
	t.Helper()
	repairCase, err := DecodeCase(readFixture(t, "v3/examples/repair-case-joinable.json"))
	if err != nil {
		t.Fatal(err)
	}
	return repairCase
}

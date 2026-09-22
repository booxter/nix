package contracts

import (
	"bytes"
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

func TestCanonicalCaseIdentityUsesJCSStringEncoding(t *testing.T) {
	t.Parallel()

	repairCase := exampleCase(t)
	repairCase.Radarr.Movie.Title = "A < B & Caf\u00e9"
	canonical, err := canonicalCaseIdentity(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(canonical, []byte(`\u003c`)) || bytes.Contains(canonical, []byte(`\u0026`)) {
		t.Fatalf("canonical JSON retained Go HTML escapes: %s", canonical)
	}
	if !bytes.Contains(canonical, []byte(`"title":"A < B & Café"`)) {
		t.Fatalf("canonical JSON does not contain the JCS string encoding: %s", canonical)
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
			encoded, err := EncodeDecision(decision)
			if err != nil {
				t.Fatal(err)
			}
			roundTripped, err := DecodeDecision(encoded)
			if err != nil {
				t.Fatal(err)
			}
			reencoded, err := EncodeDecision(roundTripped)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(reencoded, encoded) {
				t.Fatalf("second encoding differs:\n got: %s\nwant: %s", reencoded, encoded)
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

func exampleCase(t *testing.T) RepairCaseV3 {
	t.Helper()
	repairCase, err := DecodeCase(readFixture(t, "v3/examples/repair-case-joinable.json"))
	if err != nil {
		t.Fatal(err)
	}
	return repairCase
}

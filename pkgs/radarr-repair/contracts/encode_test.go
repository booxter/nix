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
	const want = "sha256:4a4aabc5110cb9a01294d6fa5b08c68c96cc462655ece7b4b0edb813b9814951"
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

func exampleCase(t *testing.T) RepairCaseV1 {
	t.Helper()
	repairCase, err := DecodeCase(readFixture(t, "v1/examples/repair-case-joinable.json"))
	if err != nil {
		t.Fatal(err)
	}
	return repairCase
}

package contracts

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readFixture(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestEmbeddedSchemasCompile(t *testing.T) {
	if _, err := caseSchema(); err != nil {
		t.Fatalf("case schema: %v", err)
	}
	if _, err := decisionSchema(); err != nil {
		t.Fatalf("decision schema: %v", err)
	}
}

func TestRepairCaseExampleDecodesAndRoundTrips(t *testing.T) {
	repairCase, err := DecodeCase(readFixture(t, "v1/examples/repair-case-joinable.json"))
	if err != nil {
		t.Fatal(err)
	}
	if repairCase.SchemaVersion != RadarrRepairV1 {
		t.Fatalf("schema version = %q", repairCase.SchemaVersion)
	}
	if len(repairCase.Files) != 2 {
		t.Fatalf("files = %d", len(repairCase.Files))
	}
	if repairCase.Files[0].Probe.Status != Ok {
		t.Fatalf("probe status = %q", repairCase.Files[0].Probe.Status)
	}
	if repairCase.Capabilities[0].OutputContainer != OutputContainerMkv {
		t.Fatalf("output container = %q", repairCase.Capabilities[0].OutputContainer)
	}

	encoded, err := json.Marshal(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeCase(encoded); err != nil {
		t.Fatalf("decode round trip: %v", err)
	}
}

func TestNullableCaseFields(t *testing.T) {
	var document map[string]any
	if err := json.Unmarshal(
		readFixture(t, "v1/examples/repair-case-joinable.json"),
		&document,
	); err != nil {
		t.Fatal(err)
	}
	movie := document["radarr"].(map[string]any)["movie"].(map[string]any)
	movie["imdb_id"] = nil
	movie["original_title"] = nil
	movie["runtime_minutes"] = nil
	encoded, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	repairCase, err := DecodeCase(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if repairCase.Radarr.Movie.ImdbID != nil ||
		repairCase.Radarr.Movie.OriginalTitle != nil ||
		repairCase.Radarr.Movie.RuntimeMinutes != nil {
		t.Fatal("nullable movie fields were not decoded as nil")
	}
}

func TestDecisionExamplesDecodeToOneVariant(t *testing.T) {
	tests := []struct {
		path string
		kind DecisionAction
	}{
		{"v1/examples/repair-decision-join.json", ActionJoinParts},
		{"v1/examples/repair-decision-no-repair.json", ActionNoRepair},
	}
	for _, test := range tests {
		t.Run(string(test.kind), func(t *testing.T) {
			decision, err := DecodeDecision(readFixture(t, test.path))
			if err != nil {
				t.Fatal(err)
			}
			if decision.Kind != test.kind {
				t.Fatalf("decision kind = %q", decision.Kind)
			}
			if (decision.NoRepair == nil) == (decision.JoinParts == nil) {
				t.Fatal("expected exactly one populated decision variant")
			}
			if decision.CaseID() == "" {
				t.Fatal("empty case ID")
			}
		})
	}
}

func TestNegativeContractFixturesAreRejected(t *testing.T) {
	paths, err := filepath.Glob("../contract-tests/v1/decision-*.json")
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) == 0 {
		t.Fatal("no negative decision fixtures found")
	}
	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			if _, err := DecodeDecision(readFixture(t, path)); err == nil {
				t.Fatal("invalid decision was accepted")
			}
		})
	}

	if _, err := DecodeCase(
		readFixture(t, "../contract-tests/v1/request-unknown-field.json"),
	); err == nil {
		t.Fatal("repair case with an unknown field was accepted")
	}
}

func TestDecodeRejectsInvalidFormatAndTrailingJSON(t *testing.T) {
	validCase := readFixture(t, "v1/examples/repair-case-joinable.json")
	invalidTime := bytes.Replace(
		validCase,
		[]byte("2026-09-06T01:00:00Z"),
		[]byte("not-a-timestamp"),
		1,
	)
	if _, err := DecodeCase(invalidTime); err == nil {
		t.Fatal("repair case with invalid date-time was accepted")
	}
	if _, err := DecodeCase(append(validCase, []byte("\n{}")...)); err == nil {
		t.Fatal("repair case with trailing JSON was accepted")
	}

	validDecision := readFixture(t, "v1/examples/repair-decision-join.json")
	if _, err := DecodeDecision(append(validDecision, []byte("\nnull")...)); err == nil {
		t.Fatal("repair decision with trailing JSON was accepted")
	}
}

func TestDecodeRejectsControlCharacters(t *testing.T) {
	validDecision := readFixture(t, "v1/examples/repair-decision-no-repair.json")
	withTab := strings.Replace(
		string(validDecision),
		"The filenames",
		"The\\tfilenames",
		1,
	)
	if _, err := DecodeDecision([]byte(withTab)); err == nil {
		t.Fatal("decision explanation with a control character was accepted")
	}
}

package contracts

import (
	"bytes"
	"encoding/json"
	"fmt"
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

func TestAllRepairCaseExamplesDecode(t *testing.T) {
	paths, err := filepath.Glob("v1/examples/repair-case-*.json")
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) < 4 {
		t.Fatalf("repair case examples = %d, want at least 4", len(paths))
	}
	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			repairCase, err := DecodeCase(readFixture(t, path))
			if err != nil {
				t.Fatal(err)
			}
			caseID, err := CalculateCaseID(repairCase)
			if err != nil {
				t.Fatal(err)
			}
			if caseID != repairCase.CaseID {
				t.Fatalf("case ID = %q, want %q", repairCase.CaseID, caseID)
			}
		})
	}
}

func TestGeneralizedRepairCaseExamples(t *testing.T) {
	t.Parallel()

	single, err := DecodeCase(readFixture(t, "v1/examples/repair-case-single-unparseable.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(single.Files) != 1 || len(single.Capabilities) != 0 || single.Radarr.Movie != nil {
		t.Fatalf("single-file shape = %#v", single)
	}
	if len(single.Radarr.ManualImports) != 1 || len(single.Radarr.ManualImports[0].Rejections) != 0 {
		t.Fatalf("manual imports = %#v", single.Radarr.ManualImports)
	}

	rawDisc, err := DecodeCase(readFixture(t, "v1/examples/repair-case-raw-bluray.json"))
	if err != nil {
		t.Fatal(err)
	}
	if rawDisc.Files[0].Extension == nil ||
		*rawDisc.Files[0].Extension != M2Ts ||
		rawDisc.Files[0].Probe.Status != NotProbed {
		t.Fatalf("raw-disc file = %#v", rawDisc.Files[0])
	}

	episodic, err := DecodeCase(readFixture(t, "v1/examples/repair-case-episodic-release.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(episodic.Files) != 2 || len(episodic.Capabilities) != 0 {
		t.Fatalf("episodic shape = %#v", episodic)
	}
}

func TestRepairCaseRetainsLargeBoundedFileLists(t *testing.T) {
	t.Parallel()

	large := repairCaseWithFileCount(t, 152)
	encoded, err := EncodeCase(large)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeCase(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded.Files) != 152 {
		t.Fatalf("files = %d", len(decoded.Files))
	}

	overLimit := repairCaseWithFileCount(t, 1025)
	if _, err := EncodeCase(overLimit); err == nil {
		t.Fatal("repair case above the file limit was accepted")
	}
}

func repairCaseWithFileCount(t *testing.T, count int) RepairCaseV1 {
	t.Helper()
	repairCase, err := DecodeCase(readFixture(t, "v1/examples/repair-case-single-unparseable.json"))
	if err != nil {
		t.Fatal(err)
	}
	template := repairCase.Files[0]
	files := make([]FileElement, count)
	for index := range files {
		file := template
		if index > 0 {
			file.FileID = fmt.Sprintf("file:%064x", index)
		}
		file.Fingerprint = fmt.Sprintf("sha256:%064x", index+1)
		file.PathComponents = []string{fmt.Sprintf("Episode.%04d.mkv", index+1)}
		torrentIndex := int64(index)
		file.TorrentIndex = &torrentIndex
		files[index] = file
	}
	repairCase.Files = files
	repairCase.Download.FileCount = int64(count)
	repairCase.Download.TotalSizeBytes = template.SizeBytes * int64(count)
	repairCase.CaseID, err = CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	return repairCase
}

func TestGeneralizedCaseDispositionRules(t *testing.T) {
	t.Parallel()

	var document map[string]any
	if err := json.Unmarshal(
		readFixture(t, "v1/examples/repair-case-single-unparseable.json"),
		&document,
	); err != nil {
		t.Fatal(err)
	}
	file := document["files"].([]any)[0].(map[string]any)
	file["disposition"] = "evidence_only"
	data, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeCase(data); err == nil {
		t.Fatal("evidence-only file without a reason was accepted")
	}

	file["disposition_reason"] = "untracked"
	data, err = json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeCase(data); err == nil {
		t.Fatal("untracked file with torrent metadata was accepted")
	}

	file["torrent_index"] = nil
	file["wanted"] = nil
	file["bytes_completed"] = nil
	file["probe"] = map[string]any{
		"status":  "not_probed",
		"reason":  "not_probe_candidate",
		"summary": "The file is not a probe candidate.",
	}
	data, err = json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeCase(data); err != nil {
		t.Fatalf("valid untracked file was rejected: %v", err)
	}
}

func TestGeneralizedCaseAllowsEmptyRadarrMessages(t *testing.T) {
	t.Parallel()

	var document map[string]any
	if err := json.Unmarshal(
		readFixture(t, "v1/examples/repair-case-single-unparseable.json"),
		&document,
	); err != nil {
		t.Fatal(err)
	}
	failure := document["radarr"].(map[string]any)["failure"].(map[string]any)
	failure["error_message"] = ""
	failure["status_messages"] = []any{}
	data, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeCase(data); err != nil {
		t.Fatalf("empty Radarr messages were rejected: %v", err)
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

func TestAllDecisionExamplesDecode(t *testing.T) {
	paths, err := filepath.Glob("v1/examples/repair-decision-*.json")
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) < 5 {
		t.Fatalf("repair decision examples = %d, want at least 5", len(paths))
	}
	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			if _, err := DecodeDecision(readFixture(t, path)); err != nil {
				t.Fatal(err)
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

	invalidCase := readFixture(t, "../contract-tests/v1/request-unknown-field.json")
	if _, err := DecodeCase(invalidCase); err == nil {
		t.Fatal("repair case with an unknown field was accepted")
	}
	var document map[string]any
	if err := json.Unmarshal(invalidCase, &document); err != nil {
		t.Fatal(err)
	}
	delete(document, "unexpected")
	withoutUnknownField, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeCase(withoutUnknownField); err != nil {
		t.Fatalf("negative repair case fixture has another invalid field: %v", err)
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

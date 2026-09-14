package casestore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
)

func TestStoreManualImportExecutionLifecycle(t *testing.T) {
	t.Parallel()

	store, authorized := newManualImportExecutionStore(t)
	preparedAt := time.Date(
		2026,
		time.September,
		13,
		10,
		0,
		0,
		0,
		time.FixedZone("test", -4*60*60),
	)
	prepared, changed, err := store.PrepareManualImport(authorized, 70, preparedAt)
	if err != nil || !changed {
		t.Fatalf("prepare: changed = %t, error = %v", changed, err)
	}
	if prepared.State != ManualImportPrepared || prepared.CommandID != nil ||
		prepared.HistoryIDBefore != 70 ||
		prepared.PreparedAt.Location() != time.UTC || prepared.UpdatedAt != prepared.PreparedAt {
		t.Fatalf("prepared execution = %#v", prepared)
	}

	repeated, changed, err := store.PrepareManualImport(authorized, 99, preparedAt.Add(time.Hour))
	if err != nil || changed || !reflect.DeepEqual(repeated, prepared) {
		t.Fatalf("repeat preparation: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}

	requestedAt := prepared.PreparedAt.Add(time.Minute)
	requested, changed, err := store.MarkManualImportRequested(
		authorized.CaseID,
		81,
		requestedAt,
	)
	if err != nil || !changed {
		t.Fatalf("mark requested: changed = %t, error = %v", changed, err)
	}
	if requested.State != ManualImportRequested || requested.CommandID == nil ||
		*requested.CommandID != 81 || !requested.UpdatedAt.Equal(requestedAt) {
		t.Fatalf("requested execution = %#v", requested)
	}

	repeated, changed, err = store.MarkManualImportRequested(
		authorized.CaseID,
		81,
		requestedAt.Add(time.Minute),
	)
	if err != nil || changed || !reflect.DeepEqual(repeated, requested) {
		t.Fatalf("repeat request: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}
	if _, _, err := store.MarkManualImportRequested(
		authorized.CaseID,
		82,
		requestedAt.Add(time.Minute),
	); err == nil {
		t.Fatal("different Radarr command replaced the stored command")
	}

	importedAt := requestedAt.Add(2 * time.Minute)
	evidence := manualImportEvidence(authorized, importedAt.Add(-time.Minute))
	wrongEvidence := evidence
	wrongEvidence.DroppedPath = "/downloads/different.mkv"
	if _, changed, err := store.MarkManualImportImported(
		authorized,
		wrongEvidence,
		importedAt,
	); err == nil || changed {
		t.Fatalf("mismatched confirmation: changed = %t, error = %v", changed, err)
	}
	imported, changed, err := store.MarkManualImportImported(
		authorized,
		evidence,
		importedAt,
	)
	if err != nil || !changed || imported.State != ManualImportImported ||
		!imported.UpdatedAt.Equal(importedAt) || imported.Confirmation == nil ||
		imported.Confirmation.HistoryID != evidence.HistoryID ||
		imported.Confirmation.ImportedPath != evidence.ImportedPath {
		t.Fatalf("mark imported: changed = %t, record = %#v, error = %v", changed, imported, err)
	}
	repeated, changed, err = store.MarkManualImportImported(
		authorized,
		evidence,
		importedAt.Add(time.Minute),
	)
	if err != nil || changed || !reflect.DeepEqual(repeated, imported) {
		t.Fatalf("repeat imported: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}
	if _, _, err := store.MarkManualImportFailed(
		authorized.CaseID,
		importedAt.Add(time.Minute),
	); err == nil {
		t.Fatal("terminal imported state changed to failed")
	}

	stored, found, err := store.GetManualImportExecution(authorized.CaseID)
	if err != nil || !found || !reflect.DeepEqual(stored, imported) {
		t.Fatalf("stored execution: found = %t, record = %#v, error = %v", found, stored, err)
	}
}

func TestStoreManualImportCanResolveUncertainSubmission(t *testing.T) {
	t.Parallel()

	store, authorized := newManualImportExecutionStore(t)
	preparedAt := time.Date(2026, time.September, 13, 14, 0, 0, 0, time.UTC)
	if _, changed, err := store.PrepareManualImport(authorized, 0, preparedAt); err != nil || !changed {
		t.Fatalf("prepare: changed = %t, error = %v", changed, err)
	}
	evidence := manualImportEvidence(authorized, preparedAt.Add(time.Minute))
	imported, changed, err := store.MarkManualImportImported(
		authorized,
		evidence,
		preparedAt.Add(2*time.Minute),
	)
	if err != nil || !changed || imported.State != ManualImportImported ||
		imported.CommandID != nil || imported.Confirmation == nil {
		t.Fatalf("confirm uncertain import: changed = %t, record = %#v, error = %v", changed, imported, err)
	}
}

func TestStoreManualImportCanFailBeforeCommandIDIsKnown(t *testing.T) {
	t.Parallel()

	store, authorized := newManualImportExecutionStore(t)
	preparedAt := time.Date(2026, time.September, 13, 14, 0, 0, 0, time.UTC)
	if _, changed, err := store.PrepareManualImport(authorized, 0, preparedAt); err != nil || !changed {
		t.Fatalf("prepare failure case: changed = %t, error = %v", changed, err)
	}
	failed, changed, err := store.MarkManualImportFailed(
		authorized.CaseID,
		preparedAt.Add(time.Minute),
	)
	if err != nil || !changed || failed.State != ManualImportFailed || failed.CommandID != nil {
		t.Fatalf("mark failed: changed = %t, record = %#v, error = %v", changed, failed, err)
	}
	evidence := manualImportEvidence(authorized, preparedAt.Add(time.Minute))
	if _, _, err := store.MarkManualImportImported(
		authorized,
		evidence,
		preparedAt.Add(2*time.Minute),
	); err == nil {
		t.Fatal("terminal failed state changed to imported")
	}
}

func TestStoreManualImportPreparationRequiresStoredAuthorization(t *testing.T) {
	t.Parallel()

	preparedAt := time.Date(2026, time.September, 13, 14, 0, 0, 0, time.UTC)
	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	_, authorized := manualImportExecutionAssembly(t)
	if _, changed, err := store.PrepareManualImport(authorized, 0, preparedAt); err == nil || changed {
		t.Fatalf("missing case: changed = %t, error = %v", changed, err)
	}

	assembly, authorized := manualImportExecutionAssembly(t)
	store, err = New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	record, err := NewRecord(assembly)
	if err != nil {
		t.Fatal(err)
	}
	if created, err := store.Put(record); err != nil || !created {
		t.Fatalf("put case: created = %t, error = %v", created, err)
	}
	if _, changed, err := store.PrepareManualImport(authorized, 0, preparedAt); err == nil || changed ||
		!strings.Contains(err.Error(), "no stored planning decision") {
		t.Fatalf("missing decision: changed = %t, error = %v", changed, err)
	}
	if _, _, err := store.PutPlanningDecision(
		record.CaseID,
		planningDecision(t, record.CaseID),
		preparedAt,
	); err != nil {
		t.Fatal(err)
	}
	if _, changed, err := store.PrepareManualImport(authorized, 0, preparedAt); err == nil || changed ||
		!strings.Contains(err.Error(), "does not match") {
		t.Fatalf("different decision: changed = %t, error = %v", changed, err)
	}

	store, authorized = newManualImportExecutionStore(t)
	authorized.ExpectedFingerprint.Inode++
	if _, changed, err := store.PrepareManualImport(authorized, 0, preparedAt); err == nil || changed ||
		!strings.Contains(err.Error(), "does not match") {
		t.Fatalf("changed authorization: changed = %t, error = %v", changed, err)
	}
}

func TestDecodeManualImportExecutionRejectsInvalidRecords(t *testing.T) {
	t.Parallel()

	preparedAt := time.Date(2026, time.September, 13, 14, 0, 0, 0, time.UTC)
	record := ManualImportExecution{
		Version:             ManualImportExecutionVersionV1,
		CaseID:              "sha256:" + strings.Repeat("a", 64),
		CapabilityID:        "capability:manual",
		FileID:              "file:movie",
		ExpectedFingerprint: controller.FileFingerprint{SizeBytes: 1},
		State:               ManualImportPrepared,
		PreparedAt:          preparedAt,
		UpdatedAt:           preparedAt,
	}
	data, err := EncodeManualImportExecution(record)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeManualImportExecution(data)
	if err != nil || !reflect.DeepEqual(decoded, record) {
		t.Fatalf("decode: record = %#v, error = %v", decoded, err)
	}

	for name, mutate := range map[string]func(*ManualImportExecution){
		"unknown state": func(value *ManualImportExecution) { value.State = "unknown" },
		"command before request": func(value *ManualImportExecution) {
			value.CommandID = int64Pointer(81)
		},
		"backwards time": func(value *ManualImportExecution) {
			value.UpdatedAt = value.PreparedAt.Add(-time.Second)
		},
		"confirmation before import": func(value *ManualImportExecution) {
			confirmation := radarrImportConfirmation(controller.RadarrImportedFile{
				HistoryID: 1, MovieFileID: 2, MovieID: 3, DownloadID: "download",
				OccurredAt: value.PreparedAt, DroppedPath: "/downloads/movie.mkv",
				ImportedPath: "/movies/Movie/movie.mkv",
			})
			value.Confirmation = &confirmation
		},
	} {
		mutate := mutate
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			invalid := record
			mutate(&invalid)
			unchecked, err := json.Marshal(invalid)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := DecodeManualImportExecution(unchecked); err == nil {
				t.Fatal("invalid execution decoded successfully")
			}
		})
	}
	withUnknown := append(data[:len(data)-1], []byte(`,"unknown":true}`)...)
	if _, err := DecodeManualImportExecution(withUnknown); err == nil ||
		!strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("unknown-field error = %v", err)
	}
}

func newManualImportExecutionStore(
	t *testing.T,
) (*Store, decisionpolicy.AuthorizedManualImport) {
	t.Helper()
	assembly, authorized := manualImportExecutionAssembly(t)
	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	record, err := NewRecord(assembly)
	if err != nil {
		t.Fatal(err)
	}
	if created, err := store.Put(record); err != nil || !created {
		t.Fatalf("put case: created = %t, error = %v", created, err)
	}
	decision := manualImportExecutionDecision(
		t,
		assembly.Request.CaseID,
		authorized.CapabilityID,
		string(authorized.FileID),
	)
	if _, changed, err := store.PutPlanningDecision(
		record.CaseID,
		decision,
		time.Date(2026, time.September, 13, 13, 0, 0, 0, time.UTC),
	); err != nil || !changed {
		t.Fatalf("put decision: changed = %t, error = %v", changed, err)
	}
	return store, authorized
}

func manualImportExecutionAssembly(
	t *testing.T,
) (casebuilder.Assembly, decisionpolicy.AuthorizedManualImport) {
	t.Helper()
	observation := recordTestAssembly(t).LocalSnapshot.Observation
	runtimeMinutes := 60
	observation.Movie = &controller.RadarrMovie{
		ID: 42, TMDBID: 4242, Title: "Poorly Named Feature", Year: 2026,
		RuntimeMinutes: &runtimeMinutes,
	}
	durationMS := int64(runtimeMinutes * 60 * 1_000)
	size := int64(100)
	video := controller.ProbeStreamVideo
	codec := "h264"
	observation.Probes[0].Outcome = controller.SuccessfulMediaProbe(controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names: []string{"matroska"}, DurationMS: &durationMS, SizeBytes: &size,
		},
		Streams: []controller.ProbeStream{{
			Index: 0, Kind: &video, CodecName: &codec, DurationMS: &durationMS,
		}},
	})
	assembly, err := casebuilder.Assemble(observation)
	if err != nil {
		t.Fatal(err)
	}
	var capability *contracts.Capability
	for index := range assembly.Request.Capabilities {
		candidate := &assembly.Request.Capabilities[index]
		if candidate.Action == contracts.CapabilityActionManualImportFile {
			capability = candidate
			break
		}
	}
	if capability == nil || capability.FileID == nil {
		t.Fatal("assembly has no manual import capability")
	}
	decision := manualImportExecutionDecision(
		t,
		assembly.Request.CaseID,
		capability.CapabilityID,
		*capability.FileID,
	)
	validation := decisionpolicy.ValidateManualImport(assembly, decision)
	if !validation.Accepted() || validation.Authorized == nil {
		t.Fatalf("manual import validation = %#v", validation)
	}
	return assembly, *validation.Authorized
}

func manualImportExecutionDecision(
	t *testing.T,
	caseID string,
	capabilityID string,
	fileID string,
) contracts.RepairDecisionV1 {
	t.Helper()
	data, err := os.ReadFile("../../contracts/v1/examples/repair-decision-manual-import.json")
	if err != nil {
		t.Fatal(err)
	}
	decision, err := contracts.DecodeDecision(data)
	if err != nil {
		t.Fatal(err)
	}
	decision.ManualImportFile.CaseID = caseID
	decision.ManualImportFile.CapabilityID = capabilityID
	decision.ManualImportFile.FileID = fileID
	return decision
}

func manualImportEvidence(
	authorized decisionpolicy.AuthorizedManualImport,
	occurredAt time.Time,
) controller.RadarrImportedFile {
	return controller.RadarrImportedFile{
		HistoryID: 71, MovieFileID: 72, MovieID: authorized.File.MovieID,
		DownloadID: authorized.File.DownloadID, OccurredAt: occurredAt,
		DroppedPath:  authorized.File.Path,
		ImportedPath: "/movies/Poorly Named Feature (2026)/Poorly Named Feature.mkv",
	}
}

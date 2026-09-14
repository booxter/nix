package casestore

import (
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestStoreGetsPlannedCase(t *testing.T) {
	t.Parallel()

	assembly, authorized := manualImportExecutionAssembly(t)
	decision := manualImportExecutionDecision(
		t,
		assembly.Request.CaseID,
		authorized.CapabilityID,
		string(authorized.FileID),
	)
	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	if created, err := store.PutAssembly(assembly); err != nil || !created {
		t.Fatalf("put case: created = %t, error = %v", created, err)
	}
	if _, changed, err := store.PutPlanningDecision(
		assembly.Request.CaseID,
		decision,
		time.Date(2026, time.September, 13, 13, 0, 0, 0, time.UTC),
	); err != nil || !changed {
		t.Fatalf("put decision: changed = %t, error = %v", changed, err)
	}

	planned, err := store.GetPlannedCase(assembly.Request.CaseID)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(planned.Assembly, assembly) ||
		!reflect.DeepEqual(planned.Decision, decision) {
		t.Fatalf("planned case = %#v", planned)
	}
}

func TestStoreRequiresCaseAndDecisionForPlannedCase(t *testing.T) {
	t.Parallel()

	assembly, _ := manualImportExecutionAssembly(t)
	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.GetPlannedCase(assembly.Request.CaseID); err == nil ||
		!strings.Contains(err.Error(), "is not stored") {
		t.Fatalf("missing-case error = %v", err)
	}
	if created, err := store.PutAssembly(assembly); err != nil || !created {
		t.Fatalf("put case: created = %t, error = %v", created, err)
	}
	if _, err := store.GetPlannedCase(assembly.Request.CaseID); err == nil ||
		!strings.Contains(err.Error(), "no stored planning decision") {
		t.Fatalf("missing-decision error = %v", err)
	}
}

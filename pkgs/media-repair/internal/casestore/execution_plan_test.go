package casestore

import (
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
)

func TestReconsideredPlanAuthorizesExecutionAgainstEffectiveDecision(t *testing.T) {
	t.Parallel()
	assembly, initiallyAuthorized := manualImportExecutionAssembly(t)
	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	if created, err := store.PutAssembly(assembly); err != nil || !created {
		t.Fatalf("PutAssembly() = (%t, %v)", created, err)
	}
	base := planningDecision(t, assembly.Request.CaseID)
	if _, changed, err := store.PutPlanningDecision(
		assembly.Request.CaseID, base, assembly.Request.ObservedAt,
	); err != nil || !changed {
		t.Fatalf("PutPlanningDecision() = (%#v, %t, %v)", base, changed, err)
	}
	effectiveDecision := manualImportExecutionDecision(
		t, assembly.Request.CaseID, initiallyAuthorized.CapabilityID,
		string(initiallyAuthorized.FileID),
	)
	effectiveObservation := assembly.LocalSnapshot.Observation
	effectiveObservation.ObservedAt = assembly.Request.ObservedAt.Add(time.Minute)
	effectiveAssembly, err := casebuilder.Assemble(effectiveObservation)
	if err != nil {
		t.Fatal(err)
	}
	overrides := &reconsideration.PolicyOverrides{
		MaximumRuntimeDifferenceMS: 30 * 60 * 1_000,
	}
	effective := PlannedCase{
		Assembly: effectiveAssembly, Decision: effectiveDecision,
		ReconsiderationID: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		PolicyOverrides:   overrides,
	}
	validation := decisionpolicy.ValidateManualImportWithPolicy(
		effectiveAssembly, effectiveDecision, effective.RuntimePolicy(),
	)
	if !validation.Accepted() {
		t.Fatalf("effective validation = %#v", validation)
	}
	if _, _, err := store.PrepareManualImport(
		*validation.Authorized, 0, assembly.Request.ObservedAt,
	); err == nil {
		t.Fatal("prepared reconsidered operation before its effective plan was bound")
	}
	if err := store.BindExecutionPlan(effective); err != nil {
		t.Fatal(err)
	}
	bound, err := store.GetExecutionPlan(assembly.Request.CaseID)
	if err != nil || !reflect.DeepEqual(bound.Decision, effective.Decision) ||
		bound.ReconsiderationID != effective.ReconsiderationID ||
		!reflect.DeepEqual(bound.PolicyOverrides, effective.PolicyOverrides) ||
		!bound.Assembly.Request.ObservedAt.Equal(assembly.Request.ObservedAt) {
		t.Fatalf("GetExecutionPlan() = (%#v, %v)", bound, err)
	}
	prepared, changed, err := store.PrepareManualImport(
		*validation.Authorized, 0, effectiveAssembly.Request.ObservedAt.Add(time.Minute),
	)
	if err != nil || !changed || prepared.State != ManualImportPrepared {
		t.Fatalf("PrepareManualImport() = (%#v, %t, %v)", prepared, changed, err)
	}
}

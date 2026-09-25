package lidarrrepair

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

func TestStoreUsesVersionedStatePath(t *testing.T) {
	t.Parallel()
	stateDirectory := filepath.Join(t.TempDir(), "state")
	store, err := NewStore(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	legacyPath := filepath.Join(stateDirectory, "queue-v2-1.json")
	if err := os.WriteFile(legacyPath, []byte("legacy"), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, found, err := store.Get(1); err != nil || found {
		t.Fatalf("legacy state found = %v, error = %v", found, err)
	}
	path, err := store.path(1)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(stateDirectory, "queue-v3-1.json")
	if path != want {
		t.Fatalf("state path = %q, want %q", path, want)
	}
}

func TestStoreMigratesLegacyQueueState(t *testing.T) {
	t.Parallel()
	stateDirectory := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(stateDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	planned, _ := testPlannedImport(t, false)
	data, err := encodeRecord(planned)
	if err != nil {
		t.Fatal(err)
	}
	legacyPath := filepath.Join(stateDirectory, "queue-v3-1.json")
	if err := os.WriteFile(legacyPath, data, 0o600); err != nil {
		t.Fatal(err)
	}

	store, err := NewStore(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	migrated, found, err := store.Get(1)
	if err != nil || !found || migrated.QueueID != planned.QueueID ||
		string(migrated.Decision) != string(planned.Decision) {
		t.Fatalf("migrated = %#v, found = %v, error = %v", migrated, found, err)
	}
	caseID, err := recordCaseID(planned)
	if err != nil {
		t.Fatal(err)
	}
	casePath, err := store.casePath(caseID)
	if err != nil {
		t.Fatal(err)
	}
	planningPath, err := store.planningPath(caseID)
	if err != nil {
		t.Fatal(err)
	}
	observationPath, err := store.observationPath(planned.QueueID)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{legacyPath, casePath, planningPath, observationPath} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("migrated path %q: %v", path, err)
		}
	}
}

func TestStoreTracksRepeatedObservationOfOlderCase(t *testing.T) {
	t.Parallel()
	first, _ := testPlannedImport(t, false)
	second := first
	secondCase, err := lidarrcontracts.DecodeCase(second.Case)
	if err != nil {
		t.Fatal(err)
	}
	secondCase.Queue.Messages = []string{"different evidence"}
	secondCase.CaseID, err = lidarrcontracts.CalculateCaseID(secondCase)
	if err != nil {
		t.Fatal(err)
	}
	second.Case, err = lidarrcontracts.EncodeCase(secondCase)
	if err != nil {
		t.Fatal(err)
	}
	secondDecision, err := lidarrcontracts.DecodeDecision(second.Decision)
	if err != nil {
		t.Fatal(err)
	}
	secondDecision.ImportMissingTracks.CaseID = secondCase.CaseID
	second.Decision, err = lidarrcontracts.EncodeDecision(secondDecision)
	if err != nil {
		t.Fatal(err)
	}
	store, err := NewStore(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(first); err != nil {
		t.Fatal(err)
	}
	if err := store.Put(second); err != nil {
		t.Fatal(err)
	}
	if _, err := store.PutCase(first); err != nil {
		t.Fatal(err)
	}

	latest, found, err := store.Get(first.QueueID)
	if err != nil || !found || string(latest.Case) != string(first.Case) {
		t.Fatalf("latest = %#v, found = %v, error = %v", latest, found, err)
	}
}

func TestStoreRetriesFailuresWithoutReplacingCases(t *testing.T) {
	t.Parallel()
	planned, _ := testPlannedImport(t, false)
	decision, err := lidarrcontracts.DecodeDecision(planned.Decision)
	if err != nil {
		t.Fatal(err)
	}
	planned.Decision = nil
	store, err := NewStore(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	created, err := store.PutCase(planned)
	if err != nil || !created {
		t.Fatalf("created = %v, error = %v", created, err)
	}
	created, err = store.PutCase(planned)
	if err != nil || created {
		t.Fatalf("second created = %v, error = %v", created, err)
	}
	caseID, err := recordCaseID(planned)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)
	status, changed, err := store.PutFailure(
		caseID,
		planningrunner.Failure{Kind: planningrunner.FailureTimeout},
		now,
		now.Add(time.Minute),
	)
	if err != nil || !changed || status.Attempts != 1 || status.Decided {
		t.Fatalf("failed status = %#v, changed = %v, error = %v", status, changed, err)
	}
	status, changed, err = store.PutDecision(caseID, decision, now.Add(time.Minute))
	if err != nil || !changed || status.Attempts != 2 || !status.Decided {
		t.Fatalf("decided status = %#v, changed = %v, error = %v", status, changed, err)
	}
	stored, err := store.GetDecision(caseID)
	if err != nil || stored.CaseID() != caseID {
		t.Fatalf("planned = %#v, error = %v", stored, err)
	}
}

func TestStoreRefreshesLocalStateWithoutReplacingPlan(t *testing.T) {
	t.Parallel()
	planned, _ := testPlannedImport(t, false)
	decision, err := lidarrcontracts.DecodeDecision(planned.Decision)
	if err != nil {
		t.Fatal(err)
	}
	planned.Decision = nil
	store, err := NewStore(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	if created, err := store.PutCase(planned); err != nil || !created {
		t.Fatalf("first observation: created = %t, error = %v", created, err)
	}
	caseID, err := recordCaseID(planned)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.PutDecision(
		caseID,
		decision,
		time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC),
	); err != nil {
		t.Fatal(err)
	}

	refreshed := planned
	refreshed.SourceFingerprint =
		"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	if created, err := store.PutCase(refreshed); err != nil || created {
		t.Fatalf("refreshed observation: created = %t, error = %v", created, err)
	}
	stored, found, err := store.Get(planned.QueueID)
	if err != nil || !found {
		t.Fatalf("get: found = %t, error = %v", found, err)
	}
	if stored.SourceFingerprint != refreshed.SourceFingerprint ||
		stored.Decision == nil {
		t.Fatalf("stored plan = %#v", stored)
	}
}

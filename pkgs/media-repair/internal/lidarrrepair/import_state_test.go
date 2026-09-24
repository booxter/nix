package lidarrrepair

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

func TestStoreAllowsTerminalImportFollowedByAnotherCaseForQueue(t *testing.T) {
	t.Parallel()

	planned, current := testPlannedImport(t, false)
	store, err := NewStore(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(planned); err != nil {
		t.Fatal(err)
	}
	first, found, err := AuthorizeImport(planned, current)
	if err != nil || !found {
		t.Fatalf("first authorization: found = %t, error = %v", found, err)
	}
	now := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	if _, prepared, err := store.PrepareImport(first, 90, now); err != nil || !prepared {
		t.Fatalf("prepare first import: prepared = %t, error = %v", prepared, err)
	}
	if _, changed, err := store.MarkImportRequested(first.CaseID, 81, now); err != nil || !changed {
		t.Fatalf("request first import: changed = %t, error = %v", changed, err)
	}
	confirmation := []lidarr.ImportedTrack{{
		HistoryID: 91, AlbumID: 3, ArtistID: 2, TrackID: 11,
		DroppedPath: "/downloads/staged/02.flac", ImportedPath: "/music/02.flac",
		OccurredAt: now,
	}}
	if _, changed, err := store.MarkImported(first.CaseID, confirmation, now); err != nil || !changed {
		t.Fatalf("confirm first import: changed = %t, error = %v", changed, err)
	}

	secondPlanned, secondCurrent := nextImportCase(t, planned, current)
	if err := store.Put(secondPlanned); err != nil {
		t.Fatal(err)
	}
	second, found, err := AuthorizeImport(secondPlanned, secondCurrent)
	if err != nil || !found {
		t.Fatalf("second authorization: found = %t, error = %v", found, err)
	}
	if first.CaseID == second.CaseID {
		t.Fatal("second repair retained the first case ID")
	}
	execution, prepared, err := store.PrepareImport(second, 91, now.Add(time.Minute))
	if err != nil || !prepared || execution.CaseID != second.CaseID {
		t.Fatalf("second execution = %#v, prepared = %t, error = %v", execution, prepared, err)
	}
	previous, found, err := store.GetImportExecution(first.CaseID)
	if err != nil || !found || previous.State != Imported {
		t.Fatalf("previous execution = %#v, found = %t, error = %v", previous, found, err)
	}
}

func TestStoreBlocksAnotherCaseWhileQueueImportIsActive(t *testing.T) {
	t.Parallel()

	planned, current := testPlannedImport(t, false)
	store, err := NewStore(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(planned); err != nil {
		t.Fatal(err)
	}
	first, found, err := AuthorizeImport(planned, current)
	if err != nil || !found {
		t.Fatalf("first authorization: found = %t, error = %v", found, err)
	}
	now := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	if _, prepared, err := store.PrepareImport(first, 90, now); err != nil || !prepared {
		t.Fatalf("prepare first import: prepared = %t, error = %v", prepared, err)
	}

	secondPlanned, secondCurrent := nextImportCase(t, planned, current)
	if err := store.Put(secondPlanned); err != nil {
		t.Fatal(err)
	}
	second, found, err := AuthorizeImport(secondPlanned, secondCurrent)
	if err != nil || !found {
		t.Fatalf("second authorization: found = %t, error = %v", found, err)
	}
	if _, _, err := store.PrepareImport(second, 90, now); err == nil ||
		!strings.Contains(err.Error(), "has active import") {
		t.Fatalf("active import conflict error = %v", err)
	}
}

func TestStoreMigratesQueueScopedImportExecution(t *testing.T) {
	t.Parallel()

	directory := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	authorized := AuthorizedImport{
		CaseID:       "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		CapabilityID: "capability:import_missing_tracks:7", QueueID: 1,
		ArtistID: 2, AlbumID: 3, ReleaseID: 7,
		Tracks: []AuthorizedTrack{{
			ArtifactID:          "artifact:one",
			ArtifactFingerprint: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			TrackID:             11, Path: "/downloads/staged/02.flac", DownloadID: "download",
		}},
	}
	execution := executionFromAuthorization(
		authorized,
		90,
		time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC),
	)
	data, err := encodeImportExecution(execution)
	if err != nil {
		t.Fatal(err)
	}
	legacyPath := filepath.Join(directory, "import-queue-1.json")
	if err := os.WriteFile(legacyPath, data, 0o600); err != nil {
		t.Fatal(err)
	}

	store, err := NewStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	stored, found, err := store.GetImportExecution(authorized.CaseID)
	if err != nil || !found || !sameImportExecution(stored, execution) {
		t.Fatalf("migrated execution = %#v, found = %t, error = %v", stored, found, err)
	}
	if _, err := os.Stat(legacyPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy import state remains: %v", err)
	}
}

func nextImportCase(t *testing.T, planned Record, current Evidence) (Record, Evidence) {
	t.Helper()
	repairCase, err := lidarrcontracts.DecodeCase(planned.Case)
	if err != nil {
		t.Fatal(err)
	}
	repairCase.Queue.Messages = append(repairCase.Queue.Messages, "Later missing tracks")
	repairCase.CaseID, err = lidarrcontracts.CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	decision, err := lidarrcontracts.DecodeDecision(planned.Decision)
	if err != nil {
		t.Fatal(err)
	}
	decision.ImportMissingTracks.CaseID = repairCase.CaseID
	planned.Case, err = lidarrcontracts.EncodeCase(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	planned.Decision, err = lidarrcontracts.EncodeDecision(decision)
	if err != nil {
		t.Fatal(err)
	}
	current.Case = repairCase
	return planned, current
}

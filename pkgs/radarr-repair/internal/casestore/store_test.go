package casestore

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
)

func TestStorePutAndGet(t *testing.T) {
	t.Parallel()

	root := filepath.Join(t.TempDir(), "state")
	store, err := New(root)
	if err != nil {
		t.Fatal(err)
	}
	record := newRecordForTest(t)
	created, err := store.Put(record)
	if err != nil {
		t.Fatal(err)
	}
	if !created {
		t.Fatal("first put did not create a record")
	}

	stored, found, err := store.Get(record.CaseID)
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("stored record was not found")
	}
	if !reflect.DeepEqual(stored, record) {
		t.Fatalf("stored record differs:\n got: %#v\nwant: %#v", stored, record)
	}

	digest, err := caseDigest(record.CaseID)
	if err != nil {
		t.Fatal(err)
	}
	assertMode(t, root, 0o700)
	assertMode(t, filepath.Join(root, casesDirectoryName), 0o700)
	assertMode(t, filepath.Join(root, casesDirectoryName, digest+".json"), 0o600)
}

func TestStorePutIsIdempotentAcrossObservationTimes(t *testing.T) {
	t.Parallel()

	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	first := newRecordForTest(t)
	if created, err := store.Put(first); err != nil || !created {
		t.Fatalf("first put: created = %t, error = %v", created, err)
	}

	observation := first.Snapshot.Observation
	observation.ObservedAt = observation.ObservedAt.Add(6 * time.Hour)
	secondAssembly, err := casebuilder.Assemble(observation)
	if err != nil {
		t.Fatal(err)
	}
	second, err := NewRecord(secondAssembly)
	if err != nil {
		t.Fatal(err)
	}
	if second.CaseID != first.CaseID {
		t.Fatalf("case ID changed from %q to %q", first.CaseID, second.CaseID)
	}
	if created, err := store.Put(second); err != nil || created {
		t.Fatalf("second put: created = %t, error = %v", created, err)
	}

	stored, found, err := store.Get(first.CaseID)
	if err != nil || !found {
		t.Fatalf("get: found = %t, error = %v", found, err)
	}
	if !reflect.DeepEqual(stored, first) {
		t.Fatal("idempotent put replaced the original record")
	}
}

func TestStorePutRejectsDifferentLocalState(t *testing.T) {
	t.Parallel()

	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	first := newRecordForTest(t)
	if _, err := store.Put(first); err != nil {
		t.Fatal(err)
	}

	observation := first.Snapshot.Observation
	observation.Correlation.Transmission.Files[0].Priority++
	changedAssembly, err := casebuilder.Assemble(observation)
	if err != nil {
		t.Fatal(err)
	}
	changed, err := NewRecord(changedAssembly)
	if err != nil {
		t.Fatal(err)
	}
	if changed.CaseID != first.CaseID {
		t.Fatalf("test change unexpectedly changed case ID to %q", changed.CaseID)
	}
	if created, err := store.Put(changed); err == nil || created ||
		!strings.Contains(err.Error(), "different local state") {
		t.Fatalf("put: created = %t, error = %v", created, err)
	}
}

func TestStoreConcurrentPutCreatesOneRecord(t *testing.T) {
	t.Parallel()

	root := filepath.Join(t.TempDir(), "state")
	const writers = 12
	stores := make([]*Store, writers)
	for index := range stores {
		store, err := New(root)
		if err != nil {
			t.Fatal(err)
		}
		stores[index] = store
	}
	record := newRecordForTest(t)

	var wait sync.WaitGroup
	results := make(chan bool, writers)
	errors := make(chan error, writers)
	for _, store := range stores {
		wait.Add(1)
		go func() {
			defer wait.Done()
			created, err := store.Put(record)
			results <- created
			errors <- err
		}()
	}
	wait.Wait()
	close(results)
	close(errors)

	createdCount := 0
	for created := range results {
		if created {
			createdCount++
		}
	}
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
	if createdCount != 1 {
		t.Fatalf("created count = %d, want 1", createdCount)
	}
}

func TestStoreGetMissingAndRejectsInvalidCaseIDs(t *testing.T) {
	t.Parallel()

	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	missing := "sha256:" + strings.Repeat("0", 64)
	if _, found, err := store.Get(missing); err != nil || found {
		t.Fatalf("missing get: found = %t, error = %v", found, err)
	}
	for _, invalid := range []string{
		"",
		"sha256:" + strings.Repeat("0", 63),
		"sha256:" + strings.Repeat("A", 64),
		"../" + strings.Repeat("0", 64),
	} {
		if _, _, err := store.Get(invalid); err == nil {
			t.Fatalf("Get(%q) succeeded", invalid)
		}
	}
}

func TestStoreDoesNotReplaceCorruptRecord(t *testing.T) {
	t.Parallel()

	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	record := newRecordForTest(t)
	path, err := store.recordPath(record.CaseID)
	if err != nil {
		t.Fatal(err)
	}
	const corrupt = `{"not":"a case record"}`
	if err := os.WriteFile(path, []byte(corrupt), 0o600); err != nil {
		t.Fatal(err)
	}
	if created, err := store.Put(record); err == nil || created {
		t.Fatalf("put: created = %t, error = %v", created, err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != corrupt {
		t.Fatalf("corrupt record was replaced with %q", data)
	}
}

func TestNewRejectsInvalidRoots(t *testing.T) {
	t.Parallel()

	if _, err := New("relative"); err == nil {
		t.Fatal("relative root was accepted")
	}
	if _, err := New(string(filepath.Separator)); err == nil {
		t.Fatal("filesystem root was accepted")
	}
	parent := t.TempDir()
	target := filepath.Join(parent, "target")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(parent, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := New(link); err == nil {
		t.Fatal("symlink root was accepted")
	}
}

func assertMode(t *testing.T, path string, wanted os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != wanted {
		t.Fatalf("%s mode = %#o, want %#o", path, mode, wanted)
	}
}

package casestore

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestStoreSerializesRepairExecution(t *testing.T) {
	t.Parallel()

	root := filepath.Join(t.TempDir(), "state")
	store, err := New(root)
	if err != nil {
		t.Fatal(err)
	}
	first, err := store.AcquireExecution()
	if err != nil {
		t.Fatal(err)
	}
	defer first.Release()
	if second, err := store.AcquireExecution(); !errors.Is(err, ErrExecutionInProgress) {
		if second != nil {
			second.Release()
		}
		t.Fatalf("second acquisition error = %v", err)
	}
	assertMode(t, filepath.Join(root, executionLockFileName), 0o600)

	first.Release()
	reacquired, err := store.AcquireExecution()
	if err != nil {
		t.Fatalf("acquire after release: %v", err)
	}
	reacquired.Release()
}

func TestStoreRefusesSymlinkExecutionLock(t *testing.T) {
	t.Parallel()

	root := filepath.Join(t.TempDir(), "state")
	store, err := New(root)
	if err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "target")
	if err := os.WriteFile(target, []byte("unchanged"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(root, executionLockFileName)); err != nil {
		t.Fatal(err)
	}
	if lease, err := store.AcquireExecution(); err == nil {
		lease.Release()
		t.Fatal("symlink execution lock was accepted")
	}
	data, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "unchanged" {
		t.Fatalf("symlink target changed to %q", data)
	}
}

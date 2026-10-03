package wake

import (
	"os"
	"path/filepath"
	"testing"
)

func TestStoreSignalsController(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	store, err := NewStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Signal(); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(filepath.Join(directory, FileName))
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		t.Fatalf("wake marker = %#v, error = %v", info, err)
	}
	if err := store.Signal(); err != nil {
		t.Fatalf("replace wake marker: %v", err)
	}
}

func TestStoreRejectsSymlink(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	directory := filepath.Join(root, "directory")
	if err := os.Mkdir(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(directory, link); err != nil {
		t.Fatal(err)
	}
	if _, err := NewStore(link); err == nil {
		t.Fatal("symlink wake directory was accepted")
	}
}

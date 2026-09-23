package lidarrrepair

import (
	"os"
	"path/filepath"
	"testing"
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

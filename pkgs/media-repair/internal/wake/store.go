package wake

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/booxter/nix-config/media-repair/internal/privatefile"
)

const FileName = ".wake"

type Store struct {
	directory string
}

func NewStore(directory string) (*Store, error) {
	if directory == "" || !filepath.IsAbs(directory) || filepath.Clean(directory) != directory ||
		filepath.Dir(directory) == directory {
		return nil, fmt.Errorf("wake directory must be a clean absolute path")
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return nil, fmt.Errorf("inspect wake directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return nil, fmt.Errorf("wake path is not a directory")
	}
	return &Store{directory: directory}, nil
}

func (store *Store) Signal() error {
	if store == nil || store.directory == "" {
		return fmt.Errorf("wake store is not configured")
	}
	if err := privatefile.Replace(
		store.directory,
		filepath.Join(store.directory, FileName),
		[]byte{},
	); err != nil {
		return fmt.Errorf("signal controller: %w", err)
	}
	return nil
}

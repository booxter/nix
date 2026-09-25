package review

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/privatefile"
)

const snapshotFileName = "snapshot.json"

type Store struct {
	directory string
}

func NewStore(directory string) (*Store, error) {
	if directory == "" || !filepath.IsAbs(directory) || filepath.Clean(directory) != directory ||
		filepath.Dir(directory) == directory {
		return nil, fmt.Errorf("review directory must be a clean absolute path")
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return nil, fmt.Errorf("inspect review directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return nil, fmt.Errorf("review path is not a directory")
	}
	return &Store{directory: directory}, nil
}

func (store *Store) Publish(snapshot Snapshot) error {
	if store == nil || store.directory == "" {
		return fmt.Errorf("review store is not configured")
	}
	previous, found, err := store.Read()
	if err != nil {
		return err
	}
	if found && previous.Service != snapshot.Service {
		return fmt.Errorf("review directory is already bound to %s", previous.Service)
	}
	mergeHistory(&snapshot, previous, found)
	Sort(&snapshot)
	if err := snapshot.Validate(); err != nil {
		return err
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		return fmt.Errorf("encode review snapshot: %w", err)
	}
	return replaceShared(store.directory, filepath.Join(store.directory, snapshotFileName), data)
}

func (store *Store) Read() (Snapshot, bool, error) {
	if store == nil || store.directory == "" {
		return Snapshot{}, false, fmt.Errorf("review store is not configured")
	}
	data, err := os.ReadFile(filepath.Join(store.directory, snapshotFileName))
	if errors.Is(err, os.ErrNotExist) {
		return Snapshot{}, false, nil
	}
	if err != nil {
		return Snapshot{}, false, fmt.Errorf("read review snapshot: %w", err)
	}
	var snapshot Snapshot
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&snapshot); err != nil {
		return Snapshot{}, true, fmt.Errorf("decode review snapshot: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Snapshot{}, true, fmt.Errorf("decode review snapshot trailing data")
	}
	if err := snapshot.Validate(); err != nil {
		return Snapshot{}, true, fmt.Errorf("validate review snapshot: %w", err)
	}
	return snapshot, true, nil
}

func mergeHistory(current *Snapshot, previous Snapshot, found bool) {
	if !found {
		return
	}
	present := make(map[int64]struct{}, len(current.Current))
	for _, item := range current.Current {
		present[item.QueueID] = struct{}{}
	}
	history := append([]Item(nil), previous.History...)
	for _, item := range previous.Current {
		if _, ok := present[item.QueueID]; ok {
			continue
		}
		removedAt := current.GeneratedAt
		item.State = StateNoLongerQueued
		item.NoLongerQueuedAt = &removedAt
		history = append(history, item)
	}
	cutoff := current.GeneratedAt.Add(-90 * 24 * time.Hour)
	current.History = current.History[:0]
	for _, item := range history {
		if item.NoLongerQueuedAt != nil && !item.NoLongerQueuedAt.Before(cutoff) {
			current.History = append(current.History, item)
		}
	}
}

func replaceShared(directory, path string, data []byte) error {
	temporary, err := os.CreateTemp(directory, ".review-*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary review snapshot: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o640); err != nil {
		temporary.Close()
		return fmt.Errorf("set review snapshot permissions: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return fmt.Errorf("write review snapshot: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return fmt.Errorf("sync review snapshot: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close review snapshot: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("publish review snapshot: %w", err)
	}
	if err := privatefile.SyncDirectory(directory); err != nil {
		return fmt.Errorf("sync review directory: %w", err)
	}
	return nil
}

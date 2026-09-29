package queueaction

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/privatefile"
)

const resultVersion = "media-repair-queue-action-result/v1"

type State string

const (
	StateCompleted State = "completed"
	StateFailed    State = "failed"
)

type Result struct {
	Version     string    `json:"version"`
	RequestID   string    `json:"request_id"`
	State       State     `json:"state"`
	Attempts    uint64    `json:"attempts"`
	AttemptedAt time.Time `json:"attempted_at"`
	Outcome     string    `json:"outcome,omitempty"`
	Failure     string    `json:"failure,omitempty"`
}

type ResultStore struct {
	directory string
}

func NewResultStore(directory string) (*ResultStore, error) {
	if directory == "" || !filepath.IsAbs(directory) || filepath.Clean(directory) != directory ||
		filepath.Dir(directory) == directory {
		return nil, fmt.Errorf("queue action result directory must be a clean absolute path")
	}
	if err := privatefile.EnsureDirectory(directory); err != nil {
		return nil, fmt.Errorf("prepare queue action result directory: %w", err)
	}
	return &ResultStore{directory: directory}, nil
}

func (store *ResultStore) Get(request Request) (Result, bool, error) {
	if store == nil || store.directory == "" {
		return Result{}, false, fmt.Errorf("queue action result store is not configured")
	}
	if err := request.Validate(); err != nil {
		return Result{}, false, err
	}
	data, err := os.ReadFile(store.path(request.RequestID))
	if errors.Is(err, os.ErrNotExist) {
		return Result{}, false, nil
	}
	if err != nil {
		return Result{}, false, fmt.Errorf("read queue action result: %w", err)
	}
	var result Result
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return Result{}, true, fmt.Errorf("decode queue action result: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Result{}, true, fmt.Errorf("decode queue action result trailing data")
	}
	if err := validateResult(request, result); err != nil {
		return Result{}, true, err
	}
	return result, true, nil
}

func (store *ResultStore) Put(request Request, result Result) error {
	if store == nil || store.directory == "" {
		return fmt.Errorf("queue action result store is not configured")
	}
	if err := validateResult(request, result); err != nil {
		return err
	}
	data, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("encode queue action result: %w", err)
	}
	path := store.path(request.RequestID)
	temporary, err := os.CreateTemp(store.directory, ".result-*.tmp")
	if err != nil {
		return fmt.Errorf("create queue action result: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return fmt.Errorf("set queue action result permissions: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return fmt.Errorf("write queue action result: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return fmt.Errorf("sync queue action result: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close queue action result: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("publish queue action result: %w", err)
	}
	return privatefile.SyncDirectory(store.directory)
}

func (store *ResultStore) path(requestID string) string {
	return filepath.Join(store.directory, digest(requestID)+".json")
}

func validateResult(request Request, result Result) error {
	if err := request.Validate(); err != nil {
		return err
	}
	if result.Version != resultVersion || result.RequestID != request.RequestID ||
		result.Attempts == 0 || result.AttemptedAt.IsZero() ||
		result.AttemptedAt.Location() != time.UTC || result.Failure != strings.TrimSpace(result.Failure) {
		return fmt.Errorf("queue action result is invalid")
	}
	switch result.State {
	case StateCompleted:
		if result.Outcome == "" || result.Failure != "" {
			return fmt.Errorf("completed queue action result is invalid")
		}
	case StateFailed:
		if result.Failure == "" || result.Outcome != "" {
			return fmt.Errorf("failed queue action result is invalid")
		}
	default:
		return fmt.Errorf("queue action result state is invalid")
	}
	return nil
}

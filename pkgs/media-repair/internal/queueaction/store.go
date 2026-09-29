package queueaction

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/privatefile"
)

type Store struct {
	directory string
	service   Service
}

func NewStore(directory string, service Service) (*Store, error) {
	if directory == "" || !filepath.IsAbs(directory) || filepath.Clean(directory) != directory ||
		filepath.Dir(directory) == directory {
		return nil, fmt.Errorf("queue action directory must be a clean absolute path")
	}
	if service != ServiceLidarr && service != ServiceRadarr {
		return nil, fmt.Errorf("invalid queue action service %q", service)
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return nil, fmt.Errorf("inspect queue action directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return nil, fmt.Errorf("queue action path is not a directory")
	}
	return &Store{directory: directory, service: service}, nil
}

func (store *Store) Submit(request Request) (bool, error) {
	if store == nil || store.directory == "" {
		return false, fmt.Errorf("queue action store is not configured")
	}
	if err := request.Validate(); err != nil {
		return false, err
	}
	if request.Service != store.service {
		return false, fmt.Errorf("queue action request belongs to another service")
	}
	data, err := json.Marshal(request)
	if err != nil {
		return false, fmt.Errorf("encode queue action request: %w", err)
	}
	path := filepath.Join(store.directory, requestFileName(request))
	temporary, err := os.CreateTemp(store.directory, ".request-*.tmp")
	if err != nil {
		return false, fmt.Errorf("create queue action request: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o640); err != nil {
		temporary.Close()
		return false, fmt.Errorf("set queue action request permissions: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return false, fmt.Errorf("write queue action request: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return false, fmt.Errorf("sync queue action request: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return false, fmt.Errorf("close queue action request: %w", err)
	}
	if err := os.Link(temporaryPath, path); err != nil {
		if !errors.Is(err, os.ErrExist) {
			return false, fmt.Errorf("publish queue action request: %w", err)
		}
		existing, readErr := readRequest(path)
		if readErr != nil {
			return false, readErr
		}
		if existing != request {
			return false, fmt.Errorf("queue action request ID collision")
		}
		return false, nil
	}
	if err := privatefile.SyncDirectory(store.directory); err != nil {
		return false, fmt.Errorf("sync queue action directory: %w", err)
	}
	return true, nil
}

func (store *Store) Latest(caseID string) (Request, bool, error) {
	requests, err := store.list(caseID)
	if err != nil || len(requests) == 0 {
		return Request{}, false, err
	}
	return requests[0], true, nil
}

func (store *Store) List() ([]Request, error) {
	return store.list("")
}

func (store *Store) list(caseID string) ([]Request, error) {
	if store == nil || store.directory == "" {
		return nil, fmt.Errorf("queue action store is not configured")
	}
	if caseID != "" && !fingerprintPattern.MatchString(caseID) {
		return nil, fmt.Errorf("invalid queue action case ID")
	}
	entries, err := os.ReadDir(store.directory)
	if err != nil {
		return nil, fmt.Errorf("read queue action directory: %w", err)
	}
	requests := make([]Request, 0)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		request, err := readRequest(filepath.Join(store.directory, entry.Name()))
		if err != nil {
			return nil, err
		}
		if request.Service != store.service || entry.Name() != requestFileName(request) {
			return nil, fmt.Errorf("queue action request identity is inconsistent")
		}
		if caseID == "" || request.CaseID == caseID {
			requests = append(requests, request)
		}
	}
	sort.Slice(requests, func(left, right int) bool {
		if !requests[left].CreatedAt.Equal(requests[right].CreatedAt) {
			return requests[left].CreatedAt.After(requests[right].CreatedAt)
		}
		return requests[left].RequestID > requests[right].RequestID
	})
	return requests, nil
}

func requestFileName(request Request) string {
	return digest(request.CaseID) + "-" + digest(request.RequestID) + ".json"
}

func readRequest(path string) (Request, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Request{}, fmt.Errorf("read queue action request: %w", err)
	}
	var request Request
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return Request{}, fmt.Errorf("decode queue action request: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Request{}, fmt.Errorf("decode queue action request trailing data")
	}
	if err := request.Validate(); err != nil {
		return Request{}, fmt.Errorf("validate queue action request: %w", err)
	}
	return request, nil
}

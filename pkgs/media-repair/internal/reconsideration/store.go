package reconsideration

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
		return nil, fmt.Errorf("reconsideration directory must be a clean absolute path")
	}
	if service != ServiceLidarr && service != ServiceRadarr {
		return nil, fmt.Errorf("invalid reconsideration service %q", service)
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return nil, fmt.Errorf("inspect reconsideration directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return nil, fmt.Errorf("reconsideration path is not a directory")
	}
	return &Store{directory: directory, service: service}, nil
}

func (store *Store) Submit(request Request) (bool, error) {
	if store == nil || store.directory == "" {
		return false, fmt.Errorf("reconsideration store is not configured")
	}
	if err := request.Validate(); err != nil {
		return false, err
	}
	if request.Service != store.service {
		return false, fmt.Errorf("reconsideration request belongs to another service")
	}
	data, err := json.Marshal(request)
	if err != nil {
		return false, fmt.Errorf("encode reconsideration request: %w", err)
	}
	path := filepath.Join(store.directory, requestFileName(request))
	temporary, err := os.CreateTemp(store.directory, ".request-*.tmp")
	if err != nil {
		return false, fmt.Errorf("create reconsideration request: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o640); err != nil {
		temporary.Close()
		return false, fmt.Errorf("set reconsideration request permissions: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return false, fmt.Errorf("write reconsideration request: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return false, fmt.Errorf("sync reconsideration request: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return false, fmt.Errorf("close reconsideration request: %w", err)
	}
	if err := os.Link(temporaryPath, path); err != nil {
		if !errors.Is(err, os.ErrExist) {
			return false, fmt.Errorf("publish reconsideration request: %w", err)
		}
		existing, readErr := readRequest(path)
		if readErr != nil {
			return false, readErr
		}
		if existing != request {
			return false, fmt.Errorf("reconsideration request ID collision")
		}
		return false, nil
	}
	if err := privatefile.SyncDirectory(store.directory); err != nil {
		return false, fmt.Errorf("sync reconsideration directory: %w", err)
	}
	return true, nil
}

func (store *Store) Latest(caseID string) (Request, bool, error) {
	if store == nil || store.directory == "" {
		return Request{}, false, fmt.Errorf("reconsideration store is not configured")
	}
	if !fingerprintPattern.MatchString(caseID) {
		return Request{}, false, fmt.Errorf("invalid reconsideration case ID")
	}
	prefix := digest(caseID) + "-"
	entries, err := os.ReadDir(store.directory)
	if err != nil {
		return Request{}, false, fmt.Errorf("read reconsideration directory: %w", err)
	}
	requests := make([]Request, 0)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), prefix) ||
			!strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		request, err := readRequest(filepath.Join(store.directory, entry.Name()))
		if err != nil {
			return Request{}, false, err
		}
		if request.Service != store.service || request.CaseID != caseID ||
			entry.Name() != requestFileName(request) {
			return Request{}, false, fmt.Errorf("reconsideration request identity is inconsistent")
		}
		requests = append(requests, request)
	}
	if len(requests) == 0 {
		return Request{}, false, nil
	}
	sort.Slice(requests, func(left, right int) bool {
		if !requests[left].CreatedAt.Equal(requests[right].CreatedAt) {
			return requests[left].CreatedAt.After(requests[right].CreatedAt)
		}
		return requests[left].RequestID > requests[right].RequestID
	})
	return requests[0], true, nil
}

func requestFileName(request Request) string {
	return digest(request.CaseID) + "-" + digest(request.RequestID) + ".json"
}

func digest(fingerprint string) string {
	return strings.TrimPrefix(fingerprint, "sha256:")
}

func readRequest(path string) (Request, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Request{}, fmt.Errorf("read reconsideration request: %w", err)
	}
	var request Request
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return Request{}, fmt.Errorf("decode reconsideration request: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Request{}, fmt.Errorf("decode reconsideration request trailing data")
	}
	if err := request.Validate(); err != nil {
		return Request{}, fmt.Errorf("validate reconsideration request: %w", err)
	}
	return request, nil
}

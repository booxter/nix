package planningstate

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/privatefile"
)

type CaseExists func(caseID string) (bool, error)

type ResultStore struct {
	directory        string
	lock             Lock
	caseExists       CaseExists
	validateDecision planning.DecisionValidator
}

func NewResultStore(
	directory string,
	lock Lock,
	caseExists CaseExists,
	validateDecision planning.DecisionValidator,
) (*ResultStore, error) {
	switch {
	case directory == "" || !filepath.IsAbs(directory) || filepath.Clean(directory) != directory:
		return nil, fmt.Errorf("planning result directory must be a clean absolute path")
	case lock == nil:
		return nil, fmt.Errorf("planning result lock is required")
	case caseExists == nil:
		return nil, fmt.Errorf("planning case lookup is required")
	case validateDecision == nil:
		return nil, fmt.Errorf("planning decision validator is required")
	}
	if err := privatefile.EnsureDirectory(directory); err != nil {
		return nil, fmt.Errorf("prepare planning result directory: %w", err)
	}
	return &ResultStore{
		directory: directory, lock: lock, caseExists: caseExists,
		validateDecision: validateDecision,
	}, nil
}

func (store *ResultStore) Get(caseID string) (planning.StoredResult, bool, error) {
	path, err := store.Path(caseID)
	if err != nil {
		return planning.StoredResult{}, false, err
	}
	result, found, err := store.read(path)
	if err != nil {
		return planning.StoredResult{}, false, err
	}
	if found && result.CaseID != caseID {
		return planning.StoredResult{}, false, fmt.Errorf(
			"stored planning result has unexpected case ID %q", result.CaseID,
		)
	}
	return result, found, nil
}

func (store *ResultStore) PutFailure(
	caseID string,
	failure planning.Failure,
	attemptedAt time.Time,
	retryAfter time.Time,
) (planning.StoredResult, bool, error) {
	return store.update(caseID, func(previous planning.StoredResult, found bool) (
		planning.StoredResult,
		bool,
		error,
	) {
		return planning.NextFailure(previous, found, caseID, failure, attemptedAt, retryAfter)
	})
}

func (store *ResultStore) PutDecision(
	caseID string,
	decision json.RawMessage,
	attemptedAt time.Time,
) (planning.StoredResult, bool, error) {
	return store.update(caseID, func(previous planning.StoredResult, found bool) (
		planning.StoredResult,
		bool,
		error,
	) {
		return planning.NextDecision(previous, found, caseID, decision, attemptedAt)
	})
}

func (store *ResultStore) Path(caseID string) (string, error) {
	if !caseIDPattern.MatchString(caseID) {
		return "", fmt.Errorf("invalid planning case ID %q", caseID)
	}
	return filepath.Join(store.directory, caseID[len("sha256:"):]+".json"), nil
}

func (store *ResultStore) update(
	caseID string,
	update func(planning.StoredResult, bool) (planning.StoredResult, bool, error),
) (planning.StoredResult, bool, error) {
	path, err := store.Path(caseID)
	if err != nil {
		return planning.StoredResult{}, false, err
	}
	unlock, err := store.lock()
	if err != nil {
		return planning.StoredResult{}, false, err
	}
	defer unlock()

	found, err := store.caseExists(caseID)
	if err != nil {
		return planning.StoredResult{}, false, err
	}
	if !found {
		return planning.StoredResult{}, false, fmt.Errorf("case %q is not stored", caseID)
	}
	previous, found, err := store.read(path)
	if err != nil {
		return planning.StoredResult{}, false, err
	}
	if found && previous.CaseID != caseID {
		return planning.StoredResult{}, false, fmt.Errorf(
			"stored planning result has unexpected case ID %q", previous.CaseID,
		)
	}
	result, changed, err := update(previous, found)
	if err != nil || !changed {
		return result, changed, err
	}
	data, err := planning.EncodeStoredResult(result, store.validateDecision)
	if err != nil {
		return planning.StoredResult{}, false, err
	}
	if err := privatefile.Replace(store.directory, path, data); err != nil {
		return planning.StoredResult{}, false, err
	}
	return result, true, nil
}

func (store *ResultStore) read(path string) (planning.StoredResult, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return planning.StoredResult{}, false, nil
	}
	if err != nil {
		return planning.StoredResult{}, false, fmt.Errorf("read planning result: %w", err)
	}
	result, err := planning.DecodeStoredResult(data, store.validateDecision)
	if err != nil {
		return planning.StoredResult{}, true, fmt.Errorf("validate stored planning result: %w", err)
	}
	return result, true, nil
}

package planningstate

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"github.com/booxter/nix-config/media-repair/internal/privatefile"
)

var caseIDPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

type Lock func() (unlock func(), err error)

type CaseCodec[Case any] struct {
	CaseID       func(Case) string
	Encode       func(Case) ([]byte, error)
	Decode       func([]byte) (Case, error)
	SameIdentity func(Case, Case) (bool, error)
	Merge        func(stored, current Case) (Case, error)
}

type CaseStore[Case any] struct {
	directory string
	lock      Lock
	codec     CaseCodec[Case]
}

type Observation struct {
	Created bool
	Updated bool
}

func NewCaseStore[Case any](
	directory string,
	lock Lock,
	codec CaseCodec[Case],
) (*CaseStore[Case], error) {
	switch {
	case directory == "" || !filepath.IsAbs(directory) || filepath.Clean(directory) != directory:
		return nil, fmt.Errorf("planning case directory must be a clean absolute path")
	case lock == nil:
		return nil, fmt.Errorf("planning case lock is required")
	case codec.CaseID == nil || codec.Encode == nil || codec.Decode == nil ||
		codec.SameIdentity == nil || codec.Merge == nil:
		return nil, fmt.Errorf("planning case codec is incomplete")
	}
	if err := privatefile.EnsureDirectory(directory); err != nil {
		return nil, fmt.Errorf("prepare planning case directory: %w", err)
	}
	return &CaseStore[Case]{directory: directory, lock: lock, codec: codec}, nil
}

func (store *CaseStore[Case]) Observe(
	current Case,
	after func() error,
) (Observation, error) {
	caseID, err := store.validate(current)
	if err != nil {
		return Observation{}, err
	}
	path, err := store.path(caseID)
	if err != nil {
		return Observation{}, err
	}
	unlock, err := store.lock()
	if err != nil {
		return Observation{}, err
	}
	defer unlock()

	stored, found, err := store.read(path)
	if err != nil {
		return Observation{}, err
	}
	result := Observation{Created: !found}
	wanted := current
	if found {
		same, compareErr := store.codec.SameIdentity(stored, current)
		if compareErr != nil {
			return Observation{}, compareErr
		}
		if !same {
			return Observation{}, fmt.Errorf(
				"case ID %q is already bound to different planning evidence", caseID,
			)
		}
		wanted, err = store.codec.Merge(stored, current)
		if err != nil {
			return Observation{}, err
		}
	}
	data, err := store.codec.Encode(wanted)
	if err != nil {
		return Observation{}, err
	}
	if !found {
		if err := privatefile.Replace(store.directory, path, data); err != nil {
			return Observation{}, fmt.Errorf("store planning case: %w", err)
		}
		result.Updated = true
	} else {
		storedData, encodeErr := store.codec.Encode(stored)
		if encodeErr != nil {
			return Observation{}, encodeErr
		}
		if !bytes.Equal(storedData, data) {
			if err := privatefile.Replace(store.directory, path, data); err != nil {
				return Observation{}, fmt.Errorf("refresh planning case observation: %w", err)
			}
			result.Updated = true
		}
	}
	if after != nil {
		if err := after(); err != nil {
			return Observation{}, err
		}
	}
	return result, nil
}

func (store *CaseStore[Case]) Get(caseID string) (Case, bool, error) {
	var zero Case
	path, err := store.path(caseID)
	if err != nil {
		return zero, false, err
	}
	stored, found, err := store.read(path)
	if err != nil || !found {
		return stored, found, err
	}
	storedID, err := store.validate(stored)
	if err != nil {
		return zero, true, err
	}
	if storedID != caseID {
		return zero, true, fmt.Errorf("stored planning case has unexpected ID %q", storedID)
	}
	return stored, true, nil
}

func (store *CaseStore[Case]) read(path string) (Case, bool, error) {
	var zero Case
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return zero, false, nil
	}
	if err != nil {
		return zero, false, fmt.Errorf("read planning case: %w", err)
	}
	record, err := store.codec.Decode(data)
	if err != nil {
		return zero, true, fmt.Errorf("validate stored planning case: %w", err)
	}
	return record, true, nil
}

func (store *CaseStore[Case]) validate(record Case) (string, error) {
	caseID := store.codec.CaseID(record)
	if !caseIDPattern.MatchString(caseID) {
		return "", fmt.Errorf("invalid planning case ID %q", caseID)
	}
	if _, err := store.codec.Encode(record); err != nil {
		return "", err
	}
	return caseID, nil
}

func (store *CaseStore[Case]) path(caseID string) (string, error) {
	if !caseIDPattern.MatchString(caseID) {
		return "", fmt.Errorf("invalid planning case ID %q", caseID)
	}
	return filepath.Join(store.directory, caseID[len("sha256:"):]+".json"), nil
}

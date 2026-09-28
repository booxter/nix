package reconsideration

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/privatefile"
)

const resultVersion = "media-repair-reconsideration-result/v1"

// Result binds a planner outcome to one immutable reconsideration request.
// The original case decision remains in the normal planning store; each newer
// request gets a separate result and therefore preserves the decision history.
type Result struct {
	Version   string                `json:"version"`
	RequestID string                `json:"request_id"`
	Outcome   planning.StoredResult `json:"outcome"`
}

func (result Result) Status() planning.Status {
	return result.Outcome.Status()
}

type ResultStore struct {
	directory        string
	validateDecision planning.DecisionValidator
}

func NewResultStore(
	directory string,
	validateDecision planning.DecisionValidator,
) (*ResultStore, error) {
	if directory == "" || !filepath.IsAbs(directory) || filepath.Clean(directory) != directory ||
		filepath.Dir(directory) == directory {
		return nil, fmt.Errorf("reconsideration result directory must be a clean absolute path")
	}
	if validateDecision == nil {
		return nil, fmt.Errorf("reconsideration decision validator is required")
	}
	if err := privatefile.EnsureDirectory(directory); err != nil {
		return nil, fmt.Errorf("prepare reconsideration result directory: %w", err)
	}
	return &ResultStore{directory: directory, validateDecision: validateDecision}, nil
}

func (store *ResultStore) Get(request Request) (Result, bool, error) {
	if err := request.Validate(); err != nil {
		return Result{}, false, err
	}
	path := store.path(request.RequestID)
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Result{}, false, nil
	}
	if err != nil {
		return Result{}, false, fmt.Errorf("read reconsideration result: %w", err)
	}
	result, err := decodeResult(data, store.validateDecision)
	if err != nil {
		return Result{}, true, fmt.Errorf("validate reconsideration result: %w", err)
	}
	if result.RequestID != request.RequestID || result.Outcome.CaseID != request.CaseID {
		return Result{}, true, fmt.Errorf("reconsideration result does not match its request")
	}
	return result, true, nil
}

func (store *ResultStore) PutFailure(
	request Request,
	failure planning.Failure,
	attemptedAt time.Time,
	retryAfter time.Time,
) (Result, bool, error) {
	return store.update(request, func(previous planning.StoredResult, found bool) (
		planning.StoredResult,
		bool,
		error,
	) {
		return planning.NextFailure(
			previous, found, request.CaseID, failure, attemptedAt, retryAfter,
		)
	})
}

func (store *ResultStore) PutDecision(
	request Request,
	decision json.RawMessage,
	attemptedAt time.Time,
) (Result, bool, error) {
	return store.update(request, func(previous planning.StoredResult, found bool) (
		planning.StoredResult,
		bool,
		error,
	) {
		return planning.NextDecision(previous, found, request.CaseID, decision, attemptedAt)
	})
}

func (store *ResultStore) update(
	request Request,
	update func(planning.StoredResult, bool) (planning.StoredResult, bool, error),
) (Result, bool, error) {
	previous, found, err := store.Get(request)
	if err != nil {
		return Result{}, false, err
	}
	outcome, changed, err := update(previous.Outcome, found)
	if err != nil || !changed {
		if found {
			return previous, changed, err
		}
		return Result{Version: resultVersion, RequestID: request.RequestID, Outcome: outcome}, changed, err
	}
	result := Result{Version: resultVersion, RequestID: request.RequestID, Outcome: outcome}
	data, err := encodeResult(result, store.validateDecision)
	if err != nil {
		return Result{}, false, err
	}
	if err := privatefile.Replace(store.directory, store.path(request.RequestID), data); err != nil {
		return Result{}, false, fmt.Errorf("store reconsideration result: %w", err)
	}
	return result, true, nil
}

func (store *ResultStore) path(requestID string) string {
	return filepath.Join(store.directory, digest(requestID)+".json")
}

func encodeResult(result Result, validateDecision planning.DecisionValidator) ([]byte, error) {
	if err := validateResult(result, validateDecision); err != nil {
		return nil, err
	}
	data, err := json.Marshal(result)
	if err != nil {
		return nil, fmt.Errorf("encode reconsideration result: %w", err)
	}
	return data, nil
}

func decodeResult(data []byte, validateDecision planning.DecisionValidator) (Result, error) {
	var result Result
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return Result{}, fmt.Errorf("decode reconsideration result: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Result{}, fmt.Errorf("decode reconsideration result trailing data")
	}
	if err := validateResult(result, validateDecision); err != nil {
		return Result{}, err
	}
	return result, nil
}

func validateResult(result Result, validateDecision planning.DecisionValidator) error {
	if result.Version != resultVersion || !fingerprintPattern.MatchString(result.RequestID) {
		return fmt.Errorf("invalid reconsideration result identity")
	}
	data, err := planning.EncodeStoredResult(result.Outcome, validateDecision)
	if err != nil {
		return err
	}
	canonical, err := planning.DecodeStoredResult(data, validateDecision)
	if err != nil {
		return err
	}
	if !bytes.Equal(result.Outcome.Decision, canonical.Decision) {
		return fmt.Errorf("reconsideration decision is not canonical")
	}
	return nil
}

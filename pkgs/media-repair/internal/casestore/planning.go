package casestore

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
)

const PlanningResultVersionV1 = "radarr-repair-planning/v1"

type PlanningFailureKind string

const (
	PlanningFailureUnavailable   PlanningFailureKind = "planner_unavailable"
	PlanningFailureTimeout       PlanningFailureKind = "planner_timeout"
	PlanningFailureHTTP          PlanningFailureKind = "planner_http_error"
	PlanningFailureInvalidResult PlanningFailureKind = "planner_invalid_result"
	PlanningFailureUnexpected    PlanningFailureKind = "planner_unexpected_error"
)

type PlanningFailure struct {
	Kind       PlanningFailureKind `json:"kind"`
	StatusCode int                 `json:"status_code,omitempty"`
}

// PlanningResult is the latest planner outcome for a case. A failure may be
// replaced by a later attempt; a decision is terminal for that case ID.
type PlanningResult struct {
	Version     string           `json:"version"`
	CaseID      string           `json:"case_id"`
	Attempts    uint64           `json:"attempts"`
	AttemptedAt time.Time        `json:"attempted_at"`
	RetryAfter  *time.Time       `json:"retry_after,omitempty"`
	Failure     *PlanningFailure `json:"failure,omitempty"`
	Decision    json.RawMessage  `json:"decision,omitempty"`
}

func (result PlanningResult) HasDecision() bool {
	return len(result.Decision) != 0
}

func EncodePlanningResult(result PlanningResult) ([]byte, error) {
	if err := validatePlanningResult(result); err != nil {
		return nil, err
	}
	data, err := json.Marshal(result)
	if err != nil {
		return nil, fmt.Errorf("encode planning result: %w", err)
	}
	return data, nil
}

func DecodePlanningResult(data []byte) (PlanningResult, error) {
	var result PlanningResult
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return PlanningResult{}, fmt.Errorf("decode planning result: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return PlanningResult{}, fmt.Errorf("decode planning result: multiple JSON values")
		}
		return PlanningResult{}, fmt.Errorf("decode planning result trailing JSON: %w", err)
	}
	if err := validatePlanningResult(result); err != nil {
		return PlanningResult{}, err
	}
	result.Decision = cloneBytes(result.Decision)
	return result, nil
}

func (store *Store) GetPlanningResult(caseID string) (PlanningResult, bool, error) {
	path, err := store.planningResultPath(caseID)
	if err != nil {
		return PlanningResult{}, false, err
	}
	result, found, err := readPlanningResult(path)
	if err != nil {
		return PlanningResult{}, false, err
	}
	if found && result.CaseID != caseID {
		return PlanningResult{}, false, fmt.Errorf(
			"stored planning result has unexpected case ID %q", result.CaseID,
		)
	}
	return result, found, nil
}

func (store *Store) PutPlanningFailure(
	caseID string,
	failure PlanningFailure,
	attemptedAt time.Time,
	retryAfter time.Time,
) (PlanningResult, bool, error) {
	return store.updatePlanningResult(caseID, func(previous PlanningResult, found bool) (
		PlanningResult,
		bool,
		error,
	) {
		if found && previous.HasDecision() {
			return previous, false, nil
		}
		attempts := uint64(1)
		if found {
			if previous.Attempts == math.MaxUint64 {
				return PlanningResult{}, false, fmt.Errorf("planning attempt count overflow")
			}
			attempts = previous.Attempts + 1
		}
		result := PlanningResult{
			Version:     PlanningResultVersionV1,
			CaseID:      caseID,
			Attempts:    attempts,
			AttemptedAt: attemptedAt.UTC(),
			RetryAfter:  timePointer(retryAfter.UTC()),
			Failure:     &failure,
		}
		return result, true, nil
	})
}

func (store *Store) PutPlanningDecision(
	caseID string,
	decision contracts.RepairDecisionV3,
	attemptedAt time.Time,
) (PlanningResult, bool, error) {
	encoded, err := contracts.EncodeDecision(decision)
	if err != nil {
		return PlanningResult{}, false, fmt.Errorf("encode planning decision: %w", err)
	}
	if decision.CaseID() != caseID {
		return PlanningResult{}, false, fmt.Errorf("planning decision case ID does not match its record")
	}
	return store.updatePlanningResult(caseID, func(previous PlanningResult, found bool) (
		PlanningResult,
		bool,
		error,
	) {
		if found && previous.HasDecision() {
			if bytes.Equal(previous.Decision, encoded) {
				return previous, false, nil
			}
			return PlanningResult{}, false, fmt.Errorf(
				"case ID %q is already bound to a different planning decision", caseID,
			)
		}
		attempts := uint64(1)
		if found {
			if previous.Attempts == math.MaxUint64 {
				return PlanningResult{}, false, fmt.Errorf("planning attempt count overflow")
			}
			attempts = previous.Attempts + 1
		}
		result := PlanningResult{
			Version:     PlanningResultVersionV1,
			CaseID:      caseID,
			Attempts:    attempts,
			AttemptedAt: attemptedAt.UTC(),
			Decision:    encoded,
		}
		return result, true, nil
	})
}

func (store *Store) updatePlanningResult(
	caseID string,
	update func(PlanningResult, bool) (PlanningResult, bool, error),
) (PlanningResult, bool, error) {
	path, err := store.planningResultPath(caseID)
	if err != nil {
		return PlanningResult{}, false, err
	}
	casePath, err := store.recordPath(caseID)
	if err != nil {
		return PlanningResult{}, false, err
	}

	lock, err := store.lock()
	if err != nil {
		return PlanningResult{}, false, err
	}
	defer unlock(lock)

	caseRecord, found, err := readRecord(casePath)
	if err != nil {
		return PlanningResult{}, false, err
	}
	if !found {
		return PlanningResult{}, false, fmt.Errorf("case %q is not stored", caseID)
	}
	if caseRecord.CaseID != caseID {
		return PlanningResult{}, false, fmt.Errorf(
			"stored record has unexpected case ID %q", caseRecord.CaseID,
		)
	}
	previous, found, err := readPlanningResult(path)
	if err != nil {
		return PlanningResult{}, false, err
	}
	if found && previous.CaseID != caseID {
		return PlanningResult{}, false, fmt.Errorf(
			"stored planning result has unexpected case ID %q", previous.CaseID,
		)
	}
	result, changed, err := update(previous, found)
	if err != nil || !changed {
		return result, changed, err
	}
	data, err := EncodePlanningResult(result)
	if err != nil {
		return PlanningResult{}, false, err
	}
	if err := replacePrivateFile(store.planningDir, path, data); err != nil {
		return PlanningResult{}, false, err
	}
	return result, true, nil
}

func (store *Store) planningResultPath(caseID string) (string, error) {
	digest, err := caseDigest(caseID)
	if err != nil {
		return "", err
	}
	return filepath.Join(store.planningDir, digest+".json"), nil
}

func readPlanningResult(path string) (PlanningResult, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return PlanningResult{}, false, nil
	}
	if err != nil {
		return PlanningResult{}, false, fmt.Errorf("read planning result: %w", err)
	}
	result, err := DecodePlanningResult(data)
	if err != nil {
		return PlanningResult{}, true, fmt.Errorf("validate stored planning result: %w", err)
	}
	return result, true, nil
}

func validatePlanningResult(result PlanningResult) error {
	if result.Version != PlanningResultVersionV1 {
		return fmt.Errorf("unsupported planning result version %q", result.Version)
	}
	if _, err := caseDigest(result.CaseID); err != nil {
		return err
	}
	if result.Attempts == 0 {
		return fmt.Errorf("planning result must contain at least one attempt")
	}
	if result.AttemptedAt.IsZero() {
		return fmt.Errorf("planning result attempt time is required")
	}
	hasDecision := len(result.Decision) != 0
	hasFailure := result.Failure != nil
	if hasDecision == hasFailure {
		return fmt.Errorf("planning result must contain exactly one decision or failure")
	}
	if hasDecision {
		if result.RetryAfter != nil {
			return fmt.Errorf("successful planning result cannot have a retry time")
		}
		decision, err := contracts.DecodeDecision(result.Decision)
		if err != nil {
			return fmt.Errorf("decode stored planning decision: %w", err)
		}
		canonical, err := contracts.EncodeDecision(decision)
		if err != nil {
			return fmt.Errorf("validate stored planning decision: %w", err)
		}
		if !bytes.Equal(result.Decision, canonical) {
			return fmt.Errorf("stored planning decision is not in canonical encoded form")
		}
		if decision.CaseID() != result.CaseID {
			return fmt.Errorf("planning decision case ID does not match its record")
		}
		return nil
	}

	if result.RetryAfter == nil || !result.RetryAfter.After(result.AttemptedAt) {
		return fmt.Errorf("failed planning result must have a later retry time")
	}
	if !validPlanningFailure(*result.Failure) {
		return fmt.Errorf("invalid planning failure")
	}
	return nil
}

func validPlanningFailure(failure PlanningFailure) bool {
	switch failure.Kind {
	case PlanningFailureHTTP:
		return failure.StatusCode >= 100 && failure.StatusCode <= 599
	case PlanningFailureUnavailable,
		PlanningFailureTimeout,
		PlanningFailureInvalidResult,
		PlanningFailureUnexpected:
		return failure.StatusCode == 0
	default:
		return false
	}
}

func timePointer(value time.Time) *time.Time {
	return &value
}

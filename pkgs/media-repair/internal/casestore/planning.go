package casestore

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
)

const PlanningResultVersionV1 = planningrunner.ResultVersionV1

type PlanningFailureKind = planningrunner.FailureKind

const (
	PlanningFailureUnavailable   = planningrunner.FailureUnavailable
	PlanningFailureTimeout       = planningrunner.FailureTimeout
	PlanningFailureHTTP          = planningrunner.FailureHTTP
	PlanningFailureInvalidResult = planningrunner.FailureInvalidResult
	PlanningFailureUnexpected    = planningrunner.FailureUnexpected
)

type PlanningFailure = planningrunner.Failure
type PlanningResult = planningrunner.StoredResult

func EncodePlanningResult(result PlanningResult) ([]byte, error) {
	return planningrunner.EncodeStoredResult(result, validateRadarrDecision)
}

func DecodePlanningResult(data []byte) (PlanningResult, error) {
	return planningrunner.DecodeStoredResult(data, validateRadarrDecision)
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
		return planningrunner.NextFailure(
			previous, found, caseID, failure, attemptedAt, retryAfter,
		)
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
		return planningrunner.NextDecision(previous, found, caseID, encoded, attemptedAt)
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

func validateRadarrDecision(data json.RawMessage) (string, json.RawMessage, error) {
	decision, err := contracts.DecodeDecision(data)
	if err != nil {
		return "", nil, fmt.Errorf("decode stored planning decision: %w", err)
	}
	canonical, err := contracts.EncodeDecision(decision)
	if err != nil {
		return "", nil, err
	}
	return decision.CaseID(), canonical, nil
}

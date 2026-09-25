package casestore

import (
	"encoding/json"
	"fmt"
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
	return store.results.Get(caseID)
}

func (store *Store) PutPlanningFailure(
	caseID string,
	failure PlanningFailure,
	attemptedAt time.Time,
	retryAfter time.Time,
) (PlanningResult, bool, error) {
	return store.results.PutFailure(caseID, failure, attemptedAt, retryAfter)
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
	return store.results.PutDecision(caseID, encoded, attemptedAt)
}

func (store *Store) planningResultPath(caseID string) (string, error) {
	return store.results.Path(caseID)
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

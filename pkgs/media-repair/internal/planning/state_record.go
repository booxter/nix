package planning

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"regexp"
	"time"
)

const ResultVersionV1 = "media-repair-planning/v1"

const (
	legacyRadarrResultVersion = "radarr-repair-planning/v1"
	legacyLidarrResultVersion = "lidarr-repair-planning/v1"
)

var caseIDPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// StoredResult is the service-neutral planner outcome for a case. Failures can
// be retried, while a decision is terminal for its case identity.
type StoredResult struct {
	Version     string          `json:"version"`
	CaseID      string          `json:"case_id"`
	Attempts    uint64          `json:"attempts"`
	AttemptedAt time.Time       `json:"attempted_at"`
	RetryAfter  *time.Time      `json:"retry_after,omitempty"`
	Failure     *Failure        `json:"failure,omitempty"`
	Decision    json.RawMessage `json:"decision,omitempty"`
}

type DecisionValidator func(json.RawMessage) (caseID string, canonical json.RawMessage, err error)

func (result StoredResult) HasDecision() bool {
	return len(result.Decision) != 0
}

func (result StoredResult) Status() Status {
	return Status{
		Attempts: result.Attempts, RetryAfter: result.RetryAfter, Decided: result.HasDecision(),
	}
}

func EncodeStoredResult(result StoredResult, validateDecision DecisionValidator) ([]byte, error) {
	if result.Version != ResultVersionV1 {
		return nil, fmt.Errorf("unsupported planning result version %q", result.Version)
	}
	if err := validateStoredResult(result, validateDecision); err != nil {
		return nil, err
	}
	data, err := json.Marshal(result)
	if err != nil {
		return nil, fmt.Errorf("encode planning result: %w", err)
	}
	return data, nil
}

func DecodeStoredResult(data []byte, validateDecision DecisionValidator) (StoredResult, error) {
	var result StoredResult
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return StoredResult{}, fmt.Errorf("decode planning result: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return StoredResult{}, fmt.Errorf("decode planning result: multiple JSON values")
		}
		return StoredResult{}, fmt.Errorf("decode planning result trailing JSON: %w", err)
	}
	if result.Version != ResultVersionV1 && result.Version != legacyRadarrResultVersion &&
		result.Version != legacyLidarrResultVersion {
		return StoredResult{}, fmt.Errorf("unsupported planning result version %q", result.Version)
	}
	if err := validateStoredResult(result, validateDecision); err != nil {
		return StoredResult{}, err
	}
	result.Decision = cloneRawMessage(result.Decision)
	return result, nil
}

func NextFailure(
	previous StoredResult,
	found bool,
	caseID string,
	failure Failure,
	attemptedAt time.Time,
	retryAfter time.Time,
) (StoredResult, bool, error) {
	if found && previous.HasDecision() {
		return previous, false, nil
	}
	attempts, err := nextAttempts(previous, found)
	if err != nil {
		return StoredResult{}, false, err
	}
	result := StoredResult{
		Version: ResultVersionV1, CaseID: caseID, Attempts: attempts,
		AttemptedAt: attemptedAt.UTC(), RetryAfter: timePointer(retryAfter.UTC()),
		Failure: &failure,
	}
	return result, true, nil
}

func NextDecision(
	previous StoredResult,
	found bool,
	caseID string,
	decision json.RawMessage,
	attemptedAt time.Time,
) (StoredResult, bool, error) {
	if found && previous.HasDecision() {
		if bytes.Equal(previous.Decision, decision) {
			return previous, false, nil
		}
		return StoredResult{}, false, fmt.Errorf(
			"case ID %q is already bound to a different planning decision", caseID,
		)
	}
	attempts, err := nextAttempts(previous, found)
	if err != nil {
		return StoredResult{}, false, err
	}
	return StoredResult{
		Version: ResultVersionV1, CaseID: caseID, Attempts: attempts,
		AttemptedAt: attemptedAt.UTC(), Decision: cloneRawMessage(decision),
	}, true, nil
}

func validateStoredResult(result StoredResult, validateDecision DecisionValidator) error {
	if !caseIDPattern.MatchString(result.CaseID) {
		return fmt.Errorf("invalid planning result case ID %q", result.CaseID)
	}
	if result.Attempts == 0 {
		return fmt.Errorf("planning result must contain at least one attempt")
	}
	if result.AttemptedAt.IsZero() {
		return fmt.Errorf("planning result attempt time is required")
	}
	hasDecision := result.HasDecision()
	hasFailure := result.Failure != nil
	if hasDecision == hasFailure {
		return fmt.Errorf("planning result must contain exactly one decision or failure")
	}
	if hasDecision {
		if result.RetryAfter != nil {
			return fmt.Errorf("successful planning result cannot have a retry time")
		}
		if validateDecision == nil {
			return fmt.Errorf("planning decision validator is required")
		}
		caseID, canonical, err := validateDecision(result.Decision)
		if err != nil {
			return fmt.Errorf("validate stored planning decision: %w", err)
		}
		if !bytes.Equal(result.Decision, canonical) {
			return fmt.Errorf("stored planning decision is not in canonical encoded form")
		}
		if caseID != result.CaseID {
			return fmt.Errorf("planning decision case ID does not match its record")
		}
		return nil
	}

	if result.RetryAfter == nil || !result.RetryAfter.After(result.AttemptedAt) {
		return fmt.Errorf("failed planning result must have a later retry time")
	}
	if !ValidFailure(*result.Failure) {
		return fmt.Errorf("invalid planning failure")
	}
	return nil
}

func nextAttempts(previous StoredResult, found bool) (uint64, error) {
	if !found {
		return 1, nil
	}
	if previous.Attempts == math.MaxUint64 {
		return 0, fmt.Errorf("planning attempt count overflow")
	}
	return previous.Attempts + 1, nil
}

func cloneRawMessage(value json.RawMessage) json.RawMessage {
	if value == nil {
		return nil
	}
	return append(json.RawMessage(nil), value...)
}

func timePointer(value time.Time) *time.Time {
	return &value
}

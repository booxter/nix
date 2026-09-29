package casestore

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
)

const executionPlanVersion = "radarr-repair-execution-plan/v1"

type executionPlanRecord struct {
	Version           string                           `json:"version"`
	CaseID            string                           `json:"case_id"`
	Decision          json.RawMessage                  `json:"decision"`
	ReconsiderationID string                           `json:"reconsideration_id,omitempty"`
	PolicyOverrides   *reconsideration.PolicyOverrides `json:"policy_overrides,omitempty"`
}

// BindExecutionPlan durably records the exact effective decision accepted for
// execution. Reconsidered decisions deliberately remain separate from the
// immutable original planner result.
func (store *Store) BindExecutionPlan(planned PlannedCase) error {
	base, err := store.GetPlannedCase(planned.Assembly.Request.CaseID)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(base.Assembly, planned.Assembly) {
		return fmt.Errorf("execution plan does not match the stored repair case")
	}
	record, err := newExecutionPlanRecord(base, planned)
	if err != nil {
		return err
	}
	path, err := store.executionPlanPath(record.CaseID)
	if err != nil {
		return err
	}
	lock, err := store.lock()
	if err != nil {
		return err
	}
	defer unlock(lock)
	previous, found, err := readExecutionPlan(path, base)
	if err != nil {
		return err
	}
	if found && reflect.DeepEqual(previous, record) {
		return nil
	}
	if found {
		executionPath, pathErr := store.executionPath(record.CaseID)
		if pathErr != nil {
			return pathErr
		}
		if _, statErr := os.Lstat(executionPath); statErr == nil {
			return fmt.Errorf("case is already bound to a different execution plan")
		} else if !errors.Is(statErr, os.ErrNotExist) {
			return fmt.Errorf("inspect existing repair execution: %w", statErr)
		}
	}
	data, err := encodeExecutionPlan(record, base)
	if err != nil {
		return err
	}
	return replacePrivateFile(store.executionPlanDir, path, data)
}

func (store *Store) GetExecutionPlan(caseID string) (PlannedCase, error) {
	base, err := store.GetPlannedCase(caseID)
	if err != nil {
		return PlannedCase{}, err
	}
	path, err := store.executionPlanPath(caseID)
	if err != nil {
		return PlannedCase{}, err
	}
	record, found, err := readExecutionPlan(path, base)
	if err != nil || !found {
		return base, err
	}
	decision, err := contracts.DecodeDecision(record.Decision)
	if err != nil {
		return PlannedCase{}, err
	}
	return PlannedCase{
		Assembly: base.Assembly, Decision: decision,
		ReconsiderationID: record.ReconsiderationID,
		PolicyOverrides:   clonePolicyOverrides(record.PolicyOverrides),
	}, nil
}

func (planned PlannedCase) RuntimePolicy() decisionpolicy.RuntimePolicy {
	if planned.PolicyOverrides == nil {
		return decisionpolicy.RuntimePolicy{}
	}
	return decisionpolicy.RuntimePolicy{
		MaximumDifferenceMS: planned.PolicyOverrides.MaximumRuntimeDifferenceMS,
	}
}

func newExecutionPlanRecord(base, planned PlannedCase) (executionPlanRecord, error) {
	decision, err := contracts.EncodeDecision(planned.Decision)
	if err != nil {
		return executionPlanRecord{}, fmt.Errorf("encode effective execution decision: %w", err)
	}
	if planned.Decision.CaseID() != base.Assembly.Request.CaseID {
		return executionPlanRecord{}, fmt.Errorf("execution decision belongs to another case")
	}
	if planned.ReconsiderationID == "" {
		if planned.PolicyOverrides != nil || !reflect.DeepEqual(planned.Decision, base.Decision) {
			return executionPlanRecord{}, fmt.Errorf("changed execution plan has no reconsideration identity")
		}
	} else {
		if _, err := caseDigest(planned.ReconsiderationID); err != nil {
			return executionPlanRecord{}, fmt.Errorf("invalid execution reconsideration identity: %w", err)
		}
		if overrides := planned.PolicyOverrides; overrides != nil &&
			(overrides.MaximumRuntimeDifferenceMS <= 0 ||
				overrides.MaximumRuntimeDifferenceMS > reconsideration.MaximumRuntimeDifferenceLimitMS) {
			return executionPlanRecord{}, fmt.Errorf("execution policy overrides are invalid")
		}
	}
	return executionPlanRecord{
		Version: executionPlanVersion, CaseID: base.Assembly.Request.CaseID,
		Decision: decision, ReconsiderationID: planned.ReconsiderationID,
		PolicyOverrides: clonePolicyOverrides(planned.PolicyOverrides),
	}, nil
}

func encodeExecutionPlan(record executionPlanRecord, base PlannedCase) ([]byte, error) {
	if err := validateExecutionPlan(record, base); err != nil {
		return nil, err
	}
	data, err := json.Marshal(record)
	if err != nil {
		return nil, fmt.Errorf("encode execution plan: %w", err)
	}
	return data, nil
}

func readExecutionPlan(path string, base PlannedCase) (executionPlanRecord, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return executionPlanRecord{}, false, nil
	}
	if err != nil {
		return executionPlanRecord{}, false, fmt.Errorf("read execution plan: %w", err)
	}
	var record executionPlanRecord
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return executionPlanRecord{}, true, fmt.Errorf("decode execution plan: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return executionPlanRecord{}, true, fmt.Errorf("decode execution plan trailing data")
	}
	if err := validateExecutionPlan(record, base); err != nil {
		return executionPlanRecord{}, true, err
	}
	record.Decision = cloneBytes(record.Decision)
	record.PolicyOverrides = clonePolicyOverrides(record.PolicyOverrides)
	return record, true, nil
}

func validateExecutionPlan(record executionPlanRecord, base PlannedCase) error {
	if record.Version != executionPlanVersion || record.CaseID != base.Assembly.Request.CaseID {
		return fmt.Errorf("execution plan identity is invalid")
	}
	decision, err := contracts.DecodeDecision(record.Decision)
	if err != nil {
		return fmt.Errorf("decode execution plan decision: %w", err)
	}
	canonical, err := contracts.EncodeDecision(decision)
	if err != nil || !bytes.Equal(canonical, record.Decision) || decision.CaseID() != record.CaseID {
		return fmt.Errorf("execution plan decision is invalid")
	}
	planned := PlannedCase{
		Assembly: base.Assembly, Decision: decision,
		ReconsiderationID: record.ReconsiderationID,
		PolicyOverrides:   record.PolicyOverrides,
	}
	wanted, err := newExecutionPlanRecord(base, planned)
	if err != nil || !reflect.DeepEqual(wanted, record) {
		return fmt.Errorf("execution plan is invalid")
	}
	return nil
}

func (store *Store) executionPlanPath(caseID string) (string, error) {
	digest, err := caseDigest(caseID)
	if err != nil {
		return "", err
	}
	return filepath.Join(store.executionPlanDir, digest+".json"), nil
}

func clonePolicyOverrides(
	overrides *reconsideration.PolicyOverrides,
) *reconsideration.PolicyOverrides {
	if overrides == nil {
		return nil
	}
	cloned := *overrides
	return &cloned
}

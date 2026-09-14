package applyselection

import (
	"fmt"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
)

type Policy struct {
	AllowedActions map[contracts.DecisionAction]bool
	Limit          int
}

func Select(
	planned []casestore.PlannedCase,
	policy Policy,
) ([]casestore.PlannedCase, error) {
	if err := validatePolicy(policy); err != nil {
		return nil, err
	}
	for _, candidate := range planned {
		if err := validateDecisionAction(candidate.Decision.Kind); err != nil {
			return nil, err
		}
	}

	selected := make([]casestore.PlannedCase, 0, min(len(planned), policy.Limit))
	for _, candidate := range planned {
		action := candidate.Decision.Kind
		if !permitted(action, policy) {
			continue
		}
		selected = append(selected, candidate)
		if len(selected) == policy.Limit {
			break
		}
	}
	return selected, nil
}

func Permitted(action contracts.DecisionAction, policy Policy) (bool, error) {
	if err := validatePolicy(policy); err != nil {
		return false, err
	}
	if err := validateDecisionAction(action); err != nil {
		return false, err
	}
	return permitted(action, policy), nil
}

func permitted(action contracts.DecisionAction, policy Policy) bool {
	return action != contracts.ActionNoRepair && policy.AllowedActions[action]
}

func validatePolicy(policy Policy) error {
	if policy.Limit <= 0 {
		return fmt.Errorf("repair limit must be positive")
	}
	for action, allowed := range policy.AllowedActions {
		if !allowed {
			continue
		}
		switch action {
		case contracts.ActionJoinParts, contracts.ActionManualImportFile:
		default:
			return fmt.Errorf("action %q cannot be allowed for repair", action)
		}
	}
	return nil
}

func validateDecisionAction(action contracts.DecisionAction) error {
	switch action {
	case contracts.ActionNoRepair,
		contracts.ActionJoinParts,
		contracts.ActionManualImportFile:
		return nil
	default:
		return fmt.Errorf("planned case has unknown action %q", action)
	}
}

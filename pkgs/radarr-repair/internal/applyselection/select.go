package applyselection

import (
	"fmt"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

type Policy struct {
	AllowedActions         map[contracts.DecisionAction]bool
	AllowedDownloadClients map[controller.DownloadClient]bool
	Limit                  int
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
		if !permitted(candidate, policy) {
			continue
		}
		selected = append(selected, candidate)
		if len(selected) == policy.Limit {
			break
		}
	}
	return selected, nil
}

func Permitted(candidate casestore.PlannedCase, policy Policy) (bool, error) {
	if err := validatePolicy(policy); err != nil {
		return false, err
	}
	if err := validateDecisionAction(candidate.Decision.Kind); err != nil {
		return false, err
	}
	return permitted(candidate, policy), nil
}

func permitted(candidate casestore.PlannedCase, policy Policy) bool {
	action := candidate.Decision.Kind
	client := candidate.Assembly.LocalSnapshot.Observation.Correlation.Download.Client
	return action != contracts.ActionNoRepair &&
		policy.AllowedActions[action] && policy.AllowedDownloadClients[client]
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
		case contracts.ActionJoinParts, contracts.ActionManualImportFile,
			contracts.ActionRemuxBluray:
		default:
			return fmt.Errorf("action %q cannot be allowed for repair", action)
		}
	}
	for client, allowed := range policy.AllowedDownloadClients {
		if !allowed {
			continue
		}
		switch client {
		case controller.DownloadClientTransmission, controller.DownloadClientSABnzbd:
		default:
			return fmt.Errorf("download client %q cannot be allowed for repair", client)
		}
	}
	return nil
}

func validateDecisionAction(action contracts.DecisionAction) error {
	switch action {
	case contracts.ActionNoRepair,
		contracts.ActionJoinParts,
		contracts.ActionManualImportFile,
		contracts.ActionRemuxBluray:
		return nil
	default:
		return fmt.Errorf("planned case has unknown action %q", action)
	}
}

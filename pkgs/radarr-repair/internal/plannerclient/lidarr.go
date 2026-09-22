package plannerclient

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/radarr-repair/lidarrcontracts"
)

func (client *Client) PlanLidarr(
	ctx context.Context,
	repairCase lidarrcontracts.Case,
) (lidarrcontracts.Decision, error) {
	payload, err := lidarrcontracts.EncodeCase(repairCase)
	if err != nil {
		return lidarrcontracts.Decision{}, fmt.Errorf("construct Lidarr planner request: %w", err)
	}
	data, err := client.postPlan(ctx, lidarrPlanningURL, payload)
	if err != nil {
		return lidarrcontracts.Decision{}, err
	}
	decision, err := lidarrcontracts.DecodeDecision(data)
	if err != nil {
		return lidarrcontracts.Decision{}, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	if decision.CaseID() != repairCase.CaseID {
		return lidarrcontracts.Decision{}, &Failure{Kind: FailureInvalidResponse}
	}
	return decision, nil
}

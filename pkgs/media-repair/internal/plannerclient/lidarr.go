package plannerclient

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

func (client *Client) PlanLidarr(
	ctx context.Context,
	repairCase lidarrcontracts.Case,
	options planning.Options,
) (lidarrcontracts.Decision, error) {
	caseData, err := lidarrcontracts.EncodeCase(repairCase)
	if err != nil {
		return lidarrcontracts.Decision{}, fmt.Errorf("construct Lidarr planner request: %w", err)
	}
	payload, err := encodeRequest(caseData, options)
	if err != nil {
		return lidarrcontracts.Decision{}, err
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

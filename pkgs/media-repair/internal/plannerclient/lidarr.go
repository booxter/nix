package plannerclient

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
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

func (client *Client) ReconsiderLidarr(
	ctx context.Context,
	repairCase lidarrcontracts.Case,
	prior lidarrcontracts.Decision,
	request reconsideration.Request,
) (lidarrcontracts.Decision, error) {
	caseData, err := lidarrcontracts.EncodeCase(repairCase)
	if err != nil {
		return lidarrcontracts.Decision{}, fmt.Errorf("encode Lidarr reconsideration case: %w", err)
	}
	decisionData, err := lidarrcontracts.EncodeDecision(prior)
	if err != nil {
		return lidarrcontracts.Decision{}, fmt.Errorf("encode prior Lidarr decision: %w", err)
	}
	payload, err := encodeReconsideration(
		json.RawMessage(caseData), json.RawMessage(decisionData), request,
	)
	if err != nil {
		return lidarrcontracts.Decision{}, err
	}
	data, err := client.postPlan(ctx, lidarrReconsiderURL, payload)
	if err != nil {
		return lidarrcontracts.Decision{}, err
	}
	decision, err := lidarrcontracts.DecodeDecision(data)
	if err != nil || decision.CaseID() != repairCase.CaseID {
		return lidarrcontracts.Decision{}, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	return decision, nil
}

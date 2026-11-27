package plannerclient

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

type request struct {
	RepairCase json.RawMessage `json:"repair_case"`
	planning.Options
}

type endpoint[Case any, Decision interface{ CaseID() string }] struct {
	url            string
	requestName    string
	encodeCase     func(Case) ([]byte, error)
	decodeDecision func([]byte) (Decision, error)
}

var radarr = endpoint[contracts.RepairCaseV3, contracts.RepairDecisionV3]{
	url:            "http://planner/radarr/plan",
	requestName:    "planner request",
	encodeCase:     contracts.EncodeCase,
	decodeDecision: contracts.DecodeDecision,
}

var lidarr = endpoint[lidarrcontracts.Case, lidarrcontracts.Decision]{
	url:            "http://planner/lidarr/plan",
	requestName:    "Lidarr planner request",
	encodeCase:     lidarrcontracts.EncodeCase,
	decodeDecision: lidarrcontracts.DecodeDecision,
}

func (client *Client) PlanRadarr(
	ctx context.Context, repairCase contracts.RepairCaseV3, options planning.Options,
) (contracts.RepairDecisionV3, error) {
	if client == nil || client.httpClient == nil || client.requestTimeout <= 0 {
		return contracts.RepairDecisionV3{}, fmt.Errorf("planner client is not configured")
	}
	return radarr.plan(ctx, client, repairCase.CaseID, repairCase, options)
}

func (client *Client) PlanLidarr(
	ctx context.Context, repairCase lidarrcontracts.Case, options planning.Options,
) (lidarrcontracts.Decision, error) {
	return lidarr.plan(ctx, client, repairCase.CaseID, repairCase, options)
}

// A valid decision for a different case must never reach the repair executor.
func (e endpoint[Case, Decision]) plan(
	ctx context.Context, client *Client, caseID string, repairCase Case, options planning.Options,
) (Decision, error) {
	var zero Decision
	caseData, err := e.encodeCase(repairCase)
	if err != nil {
		return zero, fmt.Errorf("construct %s: %w", e.requestName, err)
	}
	payload, err := json.Marshal(request{RepairCase: caseData, Options: options})
	if err != nil {
		return zero, err
	}
	data, err := client.postPlan(ctx, e.url, payload)
	if err != nil {
		return zero, err
	}

	decision, err := e.decodeDecision(data)
	if err != nil {
		return zero, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	if decision.CaseID() != caseID {
		return zero, &Failure{Kind: FailureInvalidResponse}
	}
	return decision, nil
}

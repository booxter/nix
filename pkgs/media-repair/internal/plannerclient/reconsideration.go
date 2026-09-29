package plannerclient

import (
	"encoding/json"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
)

type reconsiderationEnvelope struct {
	RepairCase       json.RawMessage         `json:"repair_case"`
	PriorDecision    json.RawMessage         `json:"prior_decision"`
	OperatorGuidance reconsiderationGuidance `json:"operator_guidance"`
}

type reconsiderationGuidance struct {
	RequestID       string                           `json:"request_id"`
	Text            string                           `json:"text"`
	PolicyOverrides *reconsideration.PolicyOverrides `json:"policy_overrides,omitempty"`
}

func encodeReconsideration(
	repairCase json.RawMessage,
	priorDecision json.RawMessage,
	request reconsideration.Request,
) ([]byte, error) {
	if err := request.Validate(); err != nil {
		return nil, err
	}
	data, err := json.Marshal(reconsiderationEnvelope{
		RepairCase: repairCase, PriorDecision: priorDecision,
		OperatorGuidance: reconsiderationGuidance{
			RequestID:       request.RequestID,
			Text:            request.Guidance,
			PolicyOverrides: request.PolicyOverrides,
		},
	})
	if err != nil {
		return nil, fmt.Errorf("encode reconsideration request: %w", err)
	}
	return data, nil
}

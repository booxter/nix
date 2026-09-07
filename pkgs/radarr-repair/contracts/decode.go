package contracts

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

func DecodeCase(data []byte) (RepairCaseV1, error) {
	var repairCase RepairCaseV1
	if err := validateAndDecode(data, caseSchema, &repairCase); err != nil {
		return RepairCaseV1{}, fmt.Errorf("invalid repair case: %w", err)
	}
	return repairCase, nil
}

func DecodeDecision(data []byte) (RepairDecisionV1, error) {
	schema, err := decisionSchema()
	if err != nil {
		return RepairDecisionV1{}, err
	}
	if err := validateJSON(data, schema); err != nil {
		return RepairDecisionV1{}, fmt.Errorf("invalid repair decision: %w", err)
	}

	var envelope struct {
		Action string `json:"action"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return RepairDecisionV1{}, fmt.Errorf("decode repair decision action: %w", err)
	}

	switch DecisionAction(envelope.Action) {
	case ActionNoRepair:
		var decision NoRepairDecision
		if err := decodeStrict(data, &decision); err != nil {
			return RepairDecisionV1{}, fmt.Errorf("decode no-repair decision: %w", err)
		}
		return RepairDecisionV1{Kind: ActionNoRepair, NoRepair: &decision}, nil
	case ActionJoinParts:
		var decision JoinDecision
		if err := decodeStrict(data, &decision); err != nil {
			return RepairDecisionV1{}, fmt.Errorf("decode join-parts decision: %w", err)
		}
		return RepairDecisionV1{Kind: ActionJoinParts, JoinParts: &decision}, nil
	case ActionManualImportFile:
		var decision ManualImportFileDecision
		if err := decodeStrict(data, &decision); err != nil {
			return RepairDecisionV1{}, fmt.Errorf("decode manual-import-file decision: %w", err)
		}
		return RepairDecisionV1{
			Kind: ActionManualImportFile, ManualImportFile: &decision,
		}, nil
	default:
		return RepairDecisionV1{}, fmt.Errorf("unsupported repair decision action %q", envelope.Action)
	}
}

func validateAndDecode(
	data []byte,
	loadSchema func() (*jsonschema.Schema, error),
	destination any,
) error {
	schema, err := loadSchema()
	if err != nil {
		return err
	}
	if err := validateJSON(data, schema); err != nil {
		return err
	}
	return decodeStrict(data, destination)
}

func validateJSON(data []byte, schema *jsonschema.Schema) error {
	document, err := jsonschema.UnmarshalJSON(bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("parse JSON: %w", err)
	}
	if err := schema.Validate(document); err != nil {
		return fmt.Errorf("validate schema: %w", err)
	}
	return nil
}

func decodeStrict(data []byte, destination any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("multiple JSON values")
		}
		return fmt.Errorf("read trailing JSON: %w", err)
	}
	return nil
}

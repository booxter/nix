package contracts

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

func DecodeCase(data []byte) (RepairCaseV3, error) {
	var repairCase RepairCaseV3
	loadSchema, err := schemaForPayload(data, caseSchemaV2, caseSchemaV3)
	if err != nil {
		return RepairCaseV3{}, fmt.Errorf("invalid repair case: %w", err)
	}
	if err := validateAndDecode(data, loadSchema, &repairCase); err != nil {
		return RepairCaseV3{}, fmt.Errorf("invalid repair case: %w", err)
	}
	return repairCase, nil
}

func DecodeDecision(data []byte) (RepairDecisionV3, error) {
	loadSchema, err := schemaForPayload(data, decisionSchemaV2, decisionSchemaV3)
	if err != nil {
		return RepairDecisionV3{}, fmt.Errorf("invalid repair decision: %w", err)
	}
	schema, err := loadSchema()
	if err != nil {
		return RepairDecisionV3{}, err
	}
	if err := validateJSON(data, schema); err != nil {
		return RepairDecisionV3{}, fmt.Errorf("invalid repair decision: %w", err)
	}

	var envelope struct {
		Action string `json:"action"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return RepairDecisionV3{}, fmt.Errorf("decode repair decision action: %w", err)
	}

	switch DecisionAction(envelope.Action) {
	case ActionNoRepair:
		var decision NoRepairDecision
		if err := decodeStrict(data, &decision); err != nil {
			return RepairDecisionV3{}, fmt.Errorf("decode no-repair decision: %w", err)
		}
		return RepairDecisionV3{Kind: ActionNoRepair, NoRepair: &decision}, nil
	case ActionJoinParts:
		var decision JoinDecision
		if err := decodeStrict(data, &decision); err != nil {
			return RepairDecisionV3{}, fmt.Errorf("decode join-parts decision: %w", err)
		}
		return RepairDecisionV3{Kind: ActionJoinParts, JoinParts: &decision}, nil
	case ActionManualImportFile:
		var decision ManualImportFileDecision
		if err := decodeStrict(data, &decision); err != nil {
			return RepairDecisionV3{}, fmt.Errorf("decode manual-import-file decision: %w", err)
		}
		return RepairDecisionV3{
			Kind: ActionManualImportFile, ManualImportFile: &decision,
		}, nil
	case ActionRemuxBluray:
		var decision RemuxBlurayDecision
		if err := decodeStrict(data, &decision); err != nil {
			return RepairDecisionV3{}, fmt.Errorf("decode Blu-ray remux decision: %w", err)
		}
		return RepairDecisionV3{Kind: ActionRemuxBluray, RemuxBluray: &decision}, nil
	case ActionRemuxDVD:
		var decision RemuxDVDDecision
		if err := decodeStrict(data, &decision); err != nil {
			return RepairDecisionV3{}, fmt.Errorf("decode DVD remux decision: %w", err)
		}
		return RepairDecisionV3{Kind: ActionRemuxDVD, RemuxDVD: &decision}, nil
	default:
		return RepairDecisionV3{}, fmt.Errorf("unsupported repair decision action %q", envelope.Action)
	}
}

type schemaLoader func() (*jsonschema.Schema, error)

func schemaForPayload(data []byte, v2, v3 schemaLoader) (schemaLoader, error) {
	var envelope struct {
		SchemaVersion string `json:"schema_version"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return nil, fmt.Errorf("decode schema version: %w", err)
	}
	switch envelope.SchemaVersion {
	case string(RadarrRepairV2):
		return v2, nil
	case string(RadarrRepairV3):
		return v3, nil
	default:
		return nil, fmt.Errorf("unsupported schema version %q", envelope.SchemaVersion)
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

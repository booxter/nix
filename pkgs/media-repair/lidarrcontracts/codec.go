package lidarrcontracts

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"github.com/gowebpki/jcs"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

type caseIdentity struct {
	SchemaVersion string       `json:"schema_version"`
	Queue         Queue        `json:"queue"`
	Album         Album        `json:"album"`
	Releases      []Release    `json:"releases"`
	Tracks        []Track      `json:"tracks"`
	Artifacts     []Artifact   `json:"artifacts"`
	Assessments   []Assessment `json:"assessments"`
	Capabilities  []Capability `json:"capabilities"`
}

func CalculateCaseID(repairCase Case) (string, error) {
	serialized, err := json.Marshal(caseIdentity{
		SchemaVersion: repairCase.SchemaVersion,
		Queue:         repairCase.Queue, Album: repairCase.Album, Releases: repairCase.Releases,
		Tracks: repairCase.Tracks, Artifacts: repairCase.Artifacts,
		Assessments: repairCase.Assessments, Capabilities: repairCase.Capabilities,
	})
	if err != nil {
		return "", fmt.Errorf("encode Lidarr repair case identity: %w", err)
	}
	canonical, err := jcs.Transform(serialized)
	if err != nil {
		return "", fmt.Errorf("canonicalize Lidarr repair case identity: %w", err)
	}
	digest := sha256.Sum256(canonical)
	return "sha256:" + hex.EncodeToString(digest[:]), nil
}

func EncodeCase(repairCase Case) ([]byte, error) {
	expectedID, err := CalculateCaseID(repairCase)
	if err != nil {
		return nil, err
	}
	if repairCase.CaseID != expectedID {
		return nil, fmt.Errorf("Lidarr repair case ID does not match its planning evidence")
	}
	schema, err := loadCaseSchema(repairCase.SchemaVersion)
	if err != nil {
		return nil, err
	}
	return encodeAndValidate(repairCase, schema, "Lidarr repair case")
}

func DecodeCase(data []byte) (Case, error) {
	version, err := schemaVersion(data)
	if err != nil {
		return Case{}, fmt.Errorf("decode Lidarr repair case schema version: %w", err)
	}
	schema, err := loadCaseSchema(version)
	if err != nil {
		return Case{}, err
	}
	var repairCase Case
	if err := validateAndDecode(data, schema, &repairCase); err != nil {
		return Case{}, fmt.Errorf("invalid Lidarr repair case: %w", err)
	}
	expectedID, err := CalculateCaseID(repairCase)
	if err != nil {
		return Case{}, err
	}
	if repairCase.CaseID != expectedID {
		return Case{}, fmt.Errorf("invalid Lidarr repair case: case ID does not match its planning evidence")
	}
	return repairCase, nil
}

func EncodeDecision(decision Decision) ([]byte, error) {
	value, err := decisionValue(decision)
	if err != nil {
		return nil, err
	}
	version, err := decisionVersion(decision)
	if err != nil {
		return nil, err
	}
	schema, err := loadDecisionSchema(version)
	if err != nil {
		return nil, err
	}
	return encodeAndValidate(value, schema, "Lidarr repair decision")
}

func DecodeDecision(data []byte) (Decision, error) {
	version, err := schemaVersion(data)
	if err != nil {
		return Decision{}, fmt.Errorf("decode Lidarr repair decision schema version: %w", err)
	}
	schema, err := loadDecisionSchema(version)
	if err != nil {
		return Decision{}, err
	}
	if err := validateJSON(data, schema); err != nil {
		return Decision{}, fmt.Errorf("invalid Lidarr repair decision: %w", err)
	}
	var envelope struct {
		Action DecisionAction `json:"action"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return Decision{}, fmt.Errorf("decode Lidarr repair decision action: %w", err)
	}
	switch envelope.Action {
	case ActionNoRepair:
		var value NoRepairDecision
		if err := decodeStrict(data, &value); err != nil {
			return Decision{}, fmt.Errorf("decode Lidarr no-repair decision: %w", err)
		}
		return Decision{Kind: ActionNoRepair, NoRepair: &value}, nil
	case ActionImportMissingTracks:
		var value ImportMissingTracksDecision
		if err := decodeStrict(data, &value); err != nil {
			return Decision{}, fmt.Errorf("decode Lidarr import-track-set decision: %w", err)
		}
		return Decision{Kind: ActionImportMissingTracks, ImportMissingTracks: &value}, nil
	default:
		return Decision{}, fmt.Errorf("unsupported Lidarr repair decision action %q", envelope.Action)
	}
}

func schemaVersion(data []byte) (string, error) {
	var envelope struct {
		SchemaVersion string `json:"schema_version"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return "", err
	}
	if envelope.SchemaVersion == "" {
		return "", fmt.Errorf("schema version is empty")
	}
	return envelope.SchemaVersion, nil
}

func decisionVersion(decision Decision) (string, error) {
	switch decision.Kind {
	case ActionNoRepair:
		if decision.NoRepair != nil {
			return decision.NoRepair.SchemaVersion, nil
		}
	case ActionImportMissingTracks:
		if decision.ImportMissingTracks != nil {
			return decision.ImportMissingTracks.SchemaVersion, nil
		}
	}
	return "", fmt.Errorf("Lidarr repair decision has no schema version")
}

func decisionValue(decision Decision) (any, error) {
	if (decision.NoRepair == nil) == (decision.ImportMissingTracks == nil) {
		return nil, fmt.Errorf("Lidarr repair decision must contain exactly one action")
	}
	switch decision.Kind {
	case ActionNoRepair:
		if decision.NoRepair != nil {
			return decision.NoRepair, nil
		}
	case ActionImportMissingTracks:
		if decision.ImportMissingTracks != nil {
			return decision.ImportMissingTracks, nil
		}
	}
	return nil, fmt.Errorf("Lidarr repair decision kind %q does not match its action", decision.Kind)
}

func encodeAndValidate(value any, schema *jsonschema.Schema, name string) ([]byte, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("encode %s: %w", name, err)
	}
	if err := validateJSON(data, schema); err != nil {
		return nil, fmt.Errorf("invalid %s: %w", name, err)
	}
	return data, nil
}

func validateAndDecode(data []byte, schema *jsonschema.Schema, target any) error {
	if err := validateJSON(data, schema); err != nil {
		return err
	}
	return decodeStrict(data, target)
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

func decodeStrict(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
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

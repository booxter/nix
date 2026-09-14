package contracts

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"

	"github.com/gowebpki/jcs"
)

type caseIdentity struct {
	Capabilities  []Capability  `json:"capabilities"`
	Download      Download      `json:"download"`
	Files         []FileElement `json:"files"`
	Radarr        Radarr        `json:"radarr"`
	SchemaVersion SchemaVersion `json:"schema_version"`
}

func CalculateCaseID(repairCase RepairCaseV2) (string, error) {
	canonical, err := canonicalCaseIdentity(repairCase)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(canonical)
	return "sha256:" + hex.EncodeToString(digest[:]), nil
}

func EncodeCase(repairCase RepairCaseV2) ([]byte, error) {
	expectedID, err := CalculateCaseID(repairCase)
	if err != nil {
		return nil, err
	}
	if repairCase.CaseID != expectedID {
		return nil, fmt.Errorf("repair case ID does not match its planning evidence")
	}

	data, err := json.Marshal(repairCase)
	if err != nil {
		return nil, fmt.Errorf("encode repair case: %w", err)
	}
	schema, err := caseSchema()
	if err != nil {
		return nil, err
	}
	if err := validateJSON(data, schema); err != nil {
		return nil, fmt.Errorf("invalid repair case: %w", err)
	}
	return data, nil
}

func EncodeDecision(decision RepairDecisionV2) ([]byte, error) {
	value, err := decisionValue(decision)
	if err != nil {
		return nil, err
	}
	data, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("encode repair decision: %w", err)
	}
	schema, err := decisionSchema()
	if err != nil {
		return nil, err
	}
	if err := validateJSON(data, schema); err != nil {
		return nil, fmt.Errorf("invalid repair decision: %w", err)
	}
	return data, nil
}

func decisionValue(decision RepairDecisionV2) (any, error) {
	set := 0
	for _, present := range []bool{
		decision.NoRepair != nil,
		decision.JoinParts != nil,
		decision.ManualImportFile != nil,
	} {
		if present {
			set++
		}
	}
	if set != 1 {
		return nil, fmt.Errorf("repair decision must contain exactly one action")
	}

	switch decision.Kind {
	case ActionNoRepair:
		if decision.NoRepair != nil {
			return decision.NoRepair, nil
		}
	case ActionJoinParts:
		if decision.JoinParts != nil {
			return decision.JoinParts, nil
		}
	case ActionManualImportFile:
		if decision.ManualImportFile != nil {
			return decision.ManualImportFile, nil
		}
	}
	return nil, fmt.Errorf("repair decision kind %q does not match its action", decision.Kind)
}

func canonicalCaseIdentity(repairCase RepairCaseV2) ([]byte, error) {
	serialized, err := json.Marshal(caseIdentity{
		Capabilities:  repairCase.Capabilities,
		Download:      repairCase.Download,
		Files:         repairCase.Files,
		Radarr:        repairCase.Radarr,
		SchemaVersion: repairCase.SchemaVersion,
	})
	if err != nil {
		return nil, fmt.Errorf("encode repair case identity: %w", err)
	}
	canonical, err := jcs.Transform(serialized)
	if err != nil {
		return nil, fmt.Errorf("canonicalize repair case identity: %w", err)
	}
	return canonical, nil
}

package contracts

import (
	"bytes"
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

func CalculateCaseID(repairCase RepairCaseV3) (string, error) {
	canonical, err := canonicalCaseIdentity(repairCase)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(canonical)
	return "sha256:" + hex.EncodeToString(digest[:]), nil
}

func SameCaseIdentity(left, right RepairCaseV3) (bool, error) {
	leftCanonical, err := canonicalCaseIdentity(left)
	if err != nil {
		return false, err
	}
	rightCanonical, err := canonicalCaseIdentity(right)
	if err != nil {
		return false, err
	}
	return bytes.Equal(leftCanonical, rightCanonical), nil
}

func EncodeCase(repairCase RepairCaseV3) ([]byte, error) {
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
	schema, err := caseSchemaV3()
	if err != nil {
		return nil, err
	}
	if err := validateJSON(data, schema); err != nil {
		return nil, fmt.Errorf("invalid repair case: %w", err)
	}
	return data, nil
}

func EncodeDecision(decision RepairDecisionV3) ([]byte, error) {
	value, err := decisionValue(decision)
	if err != nil {
		return nil, err
	}
	data, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("encode repair decision: %w", err)
	}
	schema, err := decisionSchemaV3()
	if err != nil {
		return nil, err
	}
	if err := validateJSON(data, schema); err != nil {
		return nil, fmt.Errorf("invalid repair decision: %w", err)
	}
	return data, nil
}

func decisionValue(decision RepairDecisionV3) (any, error) {
	set := 0
	for _, present := range []bool{
		decision.NoRepair != nil,
		decision.JoinParts != nil,
		decision.ManualImportFile != nil,
		decision.RemuxBluray != nil,
		decision.RemuxDVD != nil,
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
	case ActionRemuxBluray:
		if decision.RemuxBluray != nil {
			return decision.RemuxBluray, nil
		}
	case ActionRemuxDVD:
		if decision.RemuxDVD != nil {
			return decision.RemuxDVD, nil
		}
	}
	return nil, fmt.Errorf("repair decision kind %q does not match its action", decision.Kind)
}

func canonicalCaseIdentity(repairCase RepairCaseV3) ([]byte, error) {
	identity := caseIdentity{
		Capabilities:  repairCase.Capabilities,
		Download:      repairCase.Download,
		Files:         repairCase.Files,
		Radarr:        repairCase.Radarr,
		SchemaVersion: repairCase.SchemaVersion,
	}
	serialized, err := json.Marshal(identity)
	if err != nil {
		return nil, fmt.Errorf("encode repair case identity: %w", err)
	}
	canonical, err := jcs.Transform(serialized)
	if err != nil {
		return nil, fmt.Errorf("canonicalize repair case identity: %w", err)
	}
	return canonical, nil
}

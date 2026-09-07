package contracts

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"

	"github.com/gowebpki/jcs"
)

type caseIdentity struct {
	Capabilities  []CapabilityElement `json:"capabilities"`
	Download      Download            `json:"download"`
	Files         []FileElement       `json:"files"`
	Radarr        Radarr              `json:"radarr"`
	SchemaVersion SchemaVersion       `json:"schema_version"`
}

func CalculateCaseID(repairCase RepairCaseV1) (string, error) {
	canonical, err := canonicalCaseIdentity(repairCase)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(canonical)
	return "sha256:" + hex.EncodeToString(digest[:]), nil
}

func EncodeCase(repairCase RepairCaseV1) ([]byte, error) {
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

func canonicalCaseIdentity(repairCase RepairCaseV1) ([]byte, error) {
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

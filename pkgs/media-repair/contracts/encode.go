package contracts

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"

	"github.com/gowebpki/jcs"
)

type caseIdentity struct {
	Capabilities  []Capability  `json:"capabilities"`
	Download      Download      `json:"download"`
	Files         []FileElement `json:"files"`
	Radarr        Radarr        `json:"radarr"`
	SchemaVersion SchemaVersion `json:"schema_version"`
}

type caseIdentityV2 struct {
	Capabilities  []Capability  `json:"capabilities"`
	Download      Download      `json:"download"`
	Files         []FileElement `json:"files"`
	Radarr        radarrV2      `json:"radarr"`
	SchemaVersion SchemaVersion `json:"schema_version"`
}

type repairCaseV2 struct {
	Capabilities  []Capability  `json:"capabilities"`
	CaseID        string        `json:"case_id"`
	Download      Download      `json:"download"`
	Files         []FileElement `json:"files"`
	ObservedAt    time.Time     `json:"observed_at"`
	Radarr        radarrV2      `json:"radarr"`
	SchemaVersion SchemaVersion `json:"schema_version"`
}

type radarrV2 struct {
	Failure       failureV2             `json:"failure"`
	History       []HistoryElement      `json:"history"`
	ManualImports []ManualImportElement `json:"manual_imports"`
	Movie         *MovieClass           `json:"movie"`
}

type failureV2 struct {
	DownloadRef           string                   `json:"download_ref"`
	ErrorMessage          string                   `json:"error_message"`
	QueueID               int64                    `json:"queue_id"`
	Status                string                   `json:"status"`
	StatusMessages        []statusMessageElementV2 `json:"status_messages"`
	Title                 string                   `json:"title"`
	TrackedDownloadState  string                   `json:"tracked_download_state"`
	TrackedDownloadStatus string                   `json:"tracked_download_status"`
}

type statusMessageElementV2 struct {
	EvidenceID string   `json:"evidence_id"`
	Messages   []string `json:"messages"`
	Title      string   `json:"title"`
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

	value, loadSchema, err := caseValue(repairCase)
	if err != nil {
		return nil, err
	}
	data, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("encode repair case: %w", err)
	}
	schema, err := loadSchema()
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
	loadSchema, err := schemaForPayload(data, decisionSchemaV2, decisionSchemaV3)
	if err != nil {
		return nil, err
	}
	schema, err := loadSchema()
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
	var identity any = caseIdentity{
		Capabilities:  repairCase.Capabilities,
		Download:      repairCase.Download,
		Files:         repairCase.Files,
		Radarr:        repairCase.Radarr,
		SchemaVersion: repairCase.SchemaVersion,
	}
	if repairCase.SchemaVersion == RadarrRepairV2 {
		identity = caseIdentityV2{
			Capabilities:  repairCase.Capabilities,
			Download:      repairCase.Download,
			Files:         repairCase.Files,
			Radarr:        projectRadarrV2(repairCase.Radarr),
			SchemaVersion: repairCase.SchemaVersion,
		}
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

func caseValue(repairCase RepairCaseV3) (any, schemaLoader, error) {
	switch repairCase.SchemaVersion {
	case RadarrRepairV2:
		return repairCaseV2{
			Capabilities:  repairCase.Capabilities,
			CaseID:        repairCase.CaseID,
			Download:      repairCase.Download,
			Files:         repairCase.Files,
			ObservedAt:    repairCase.ObservedAt,
			Radarr:        projectRadarrV2(repairCase.Radarr),
			SchemaVersion: repairCase.SchemaVersion,
		}, caseSchemaV2, nil
	case RadarrRepairV3:
		return repairCase, caseSchemaV3, nil
	default:
		return nil, nil, fmt.Errorf("unsupported repair case schema version %q", repairCase.SchemaVersion)
	}
}

func projectRadarrV2(radarr Radarr) radarrV2 {
	statusMessages := make([]statusMessageElementV2, len(radarr.Failure.StatusMessages))
	for index, status := range radarr.Failure.StatusMessages {
		statusMessages[index] = statusMessageElementV2{
			EvidenceID: status.EvidenceID,
			Messages:   status.Messages,
			Title:      status.Title,
		}
	}
	return radarrV2{
		Failure: failureV2{
			DownloadRef:           radarr.Failure.DownloadRef,
			ErrorMessage:          radarr.Failure.ErrorMessage,
			QueueID:               radarr.Failure.QueueID,
			Status:                radarr.Failure.Status,
			StatusMessages:        statusMessages,
			Title:                 radarr.Failure.Title,
			TrackedDownloadState:  radarr.Failure.TrackedDownloadState,
			TrackedDownloadStatus: radarr.Failure.TrackedDownloadStatus,
		},
		History:       radarr.History,
		ManualImports: radarr.ManualImports,
		Movie:         radarr.Movie,
	}
}

package joinstate

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/gowebpki/jcs"
)

const (
	ExecutionVersionV1 = "radarr-repair-worker-join/v1"
	MaxExecutionBytes  = 8 << 20

	validationRequestID = "request:state-validation"
	artifactIDDomain    = "radarr-repair-worker-artifact-v1\x00"
)

type State string

const (
	Prepared  State = "prepared"
	Staged    State = "staged"
	Published State = "published"
	Discarded State = "discarded"
	Failed    State = "failed"
)

// Specification is the durable identity of a requested join. RequestID and
// other transport fields are deliberately absent so retries remain idempotent.
type Specification struct {
	ExecutionID         string                          `json:"execution_id"`
	CaseID              string                          `json:"case_id"`
	CapabilityID        string                          `json:"capability_id"`
	RootID              string                          `json:"root_id"`
	Parts               []Part                          `json:"parts"`
	OutputContainer     workercontracts.OutputContainer `json:"output_container"`
	ExpectedSourceBytes int64                           `json:"expected_source_bytes"`
	ExpectedDurationMS  int64                           `json:"expected_duration_ms"`
	DurationToleranceMS int64                           `json:"duration_tolerance_ms"`
	ExpectedStreamCount int64                           `json:"expected_stream_count"`
}

type Part struct {
	FileID              string   `json:"file_id"`
	PathComponents      []string `json:"path_components"`
	ExpectedFingerprint string   `json:"expected_fingerprint"`
}

type StagedArtifact struct {
	Fingerprint string                   `json:"fingerprint"`
	SizeBytes   int64                    `json:"size_bytes"`
	Evidence    workercontracts.Evidence `json:"evidence"`
}

type PublishedArtifact struct {
	RootID         string   `json:"root_id"`
	PathComponents []string `json:"path_components"`
}

type StageFailure struct {
	Reason workercontracts.StageJoinFailureReason `json:"reason"`
}

type Execution struct {
	Version       string             `json:"version"`
	ExecutionID   string             `json:"execution_id"`
	ArtifactID    string             `json:"artifact_id"`
	Specification Specification      `json:"specification"`
	State         State              `json:"state"`
	Staged        *StagedArtifact    `json:"staged,omitempty"`
	Published     *PublishedArtifact `json:"published,omitempty"`
	Failure       *StageFailure      `json:"failure,omitempty"`
	PreparedAt    time.Time          `json:"prepared_at"`
	UpdatedAt     time.Time          `json:"updated_at"`
}

func EncodeExecution(execution Execution) ([]byte, error) {
	if err := validateExecution(execution); err != nil {
		return nil, err
	}
	data, err := json.Marshal(execution)
	if err != nil {
		return nil, fmt.Errorf("encode join execution: %w", err)
	}
	if len(data) > MaxExecutionBytes {
		return nil, fmt.Errorf(
			"join execution is %d bytes, limit is %d",
			len(data),
			MaxExecutionBytes,
		)
	}
	return data, nil
}

func DecodeExecution(data []byte) (Execution, error) {
	if len(data) > MaxExecutionBytes {
		return Execution{}, fmt.Errorf(
			"join execution is %d bytes, limit is %d",
			len(data),
			MaxExecutionBytes,
		)
	}
	var execution Execution
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&execution); err != nil {
		return Execution{}, fmt.Errorf("decode join execution: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return Execution{}, fmt.Errorf("decode join execution: multiple JSON values")
		}
		return Execution{}, fmt.Errorf("decode join execution trailing JSON: %w", err)
	}
	if err := validateExecution(execution); err != nil {
		return Execution{}, err
	}
	return cloneExecution(execution), nil
}

func specificationFromRequest(
	request workercontracts.StageJoinRequestV1,
) (Specification, error) {
	if _, err := workercontracts.EncodeStageJoinRequest(request); err != nil {
		return Specification{}, err
	}
	parts := make([]Part, len(request.Parts))
	for index, part := range request.Parts {
		parts[index] = Part{
			FileID:              part.FileID,
			PathComponents:      append([]string(nil), part.PathComponents...),
			ExpectedFingerprint: part.ExpectedFingerprint,
		}
	}
	return Specification{
		ExecutionID:         request.ExecutionID,
		CaseID:              request.CaseID,
		CapabilityID:        request.CapabilityID,
		RootID:              request.RootID,
		Parts:               parts,
		OutputContainer:     request.OutputContainer,
		ExpectedSourceBytes: request.ExpectedSourceBytes,
		ExpectedDurationMS:  request.ExpectedDurationMS,
		DurationToleranceMS: request.DurationToleranceMS,
		ExpectedStreamCount: request.ExpectedStreamCount,
	}, nil
}

func artifactID(specification Specification) (string, error) {
	serialized, err := json.Marshal(specification)
	if err != nil {
		return "", fmt.Errorf("encode join artifact identity: %w", err)
	}
	canonical, err := jcs.Transform(serialized)
	if err != nil {
		return "", fmt.Errorf("canonicalize join artifact identity: %w", err)
	}
	digest := sha256.New()
	_, _ = digest.Write([]byte(artifactIDDomain))
	_, _ = digest.Write(canonical)
	return artifactIDPrefix + hex.EncodeToString(digest.Sum(nil)), nil
}

func validateExecution(execution Execution) error {
	if execution.Version != ExecutionVersionV1 {
		return fmt.Errorf("unsupported join execution version %q", execution.Version)
	}
	if execution.ExecutionID != execution.Specification.ExecutionID {
		return fmt.Errorf("execution ID does not match its join specification")
	}
	if err := validateSpecification(execution.Specification); err != nil {
		return err
	}
	expectedArtifactID, err := artifactID(execution.Specification)
	if err != nil {
		return err
	}
	if execution.ArtifactID != expectedArtifactID {
		return fmt.Errorf("artifact ID does not match its join specification")
	}
	if execution.PreparedAt.IsZero() || execution.UpdatedAt.IsZero() {
		return fmt.Errorf("join execution timestamps are required")
	}
	if execution.UpdatedAt.Before(execution.PreparedAt) {
		return fmt.Errorf("join execution update precedes preparation")
	}

	switch execution.State {
	case Prepared:
		if execution.Staged != nil || execution.Published != nil || execution.Failure != nil {
			return fmt.Errorf("prepared join execution contains outcome data")
		}
	case Staged, Discarded:
		if execution.Staged == nil || execution.Published != nil || execution.Failure != nil {
			return fmt.Errorf("%s join execution has inconsistent outcome data", execution.State)
		}
		if err := validateStaged(execution.ArtifactID, *execution.Staged); err != nil {
			return err
		}
	case Published:
		if execution.Staged == nil || execution.Published == nil || execution.Failure != nil {
			return fmt.Errorf("published join execution has inconsistent outcome data")
		}
		if err := validateStaged(execution.ArtifactID, *execution.Staged); err != nil {
			return err
		}
		if err := validatePublished(
			execution.ArtifactID,
			execution.Staged.Fingerprint,
			*execution.Published,
		); err != nil {
			return err
		}
	case Failed:
		if execution.Staged != nil || execution.Published != nil || execution.Failure == nil {
			return fmt.Errorf("failed join execution has inconsistent outcome data")
		}
		if err := validateFailure(*execution.Failure); err != nil {
			return err
		}
	default:
		return fmt.Errorf("unsupported join execution state %q", execution.State)
	}
	return nil
}

func validateSpecification(specification Specification) error {
	parts := make([]workercontracts.StageJoinPartV1, len(specification.Parts))
	for index, part := range specification.Parts {
		parts[index] = workercontracts.StageJoinPartV1{
			ExpectedFingerprint: part.ExpectedFingerprint,
			FileID:              part.FileID,
			PathComponents:      append([]string(nil), part.PathComponents...),
		}
	}
	_, err := workercontracts.EncodeStageJoinRequest(workercontracts.StageJoinRequestV1{
		CapabilityID:        specification.CapabilityID,
		CaseID:              specification.CaseID,
		DurationToleranceMS: specification.DurationToleranceMS,
		ExecutionID:         specification.ExecutionID,
		ExpectedDurationMS:  specification.ExpectedDurationMS,
		ExpectedSourceBytes: specification.ExpectedSourceBytes,
		ExpectedStreamCount: specification.ExpectedStreamCount,
		Operation:           workercontracts.StageJoinV1,
		OutputContainer:     specification.OutputContainer,
		Parts:               parts,
		RequestID:           validationRequestID,
		RootID:              specification.RootID,
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	})
	if err != nil {
		return fmt.Errorf("validate stored join specification: %w", err)
	}
	return nil
}

func validateStaged(artifactID string, staged StagedArtifact) error {
	_, err := workercontracts.EncodeStageJoinResponse(workercontracts.StageJoinResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.StageJoinSuccessResponseV1{
			ArtifactFingerprint: staged.Fingerprint,
			ArtifactID:          artifactID,
			Evidence:            staged.Evidence,
			Operation:           workercontracts.StageJoinV1,
			RequestID:           validationRequestID,
			SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
			SizeBytes:           staged.SizeBytes,
			Status:              workercontracts.Ok,
		},
	})
	if err != nil {
		return fmt.Errorf("validate stored staged artifact: %w", err)
	}
	return nil
}

func validatePublished(
	artifactID string,
	fingerprint string,
	published PublishedArtifact,
) error {
	_, err := workercontracts.EncodePublishResponse(workercontracts.PublishResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.PublishSuccessResponseV1{
			ArtifactFingerprint: fingerprint,
			ArtifactID:          artifactID,
			Operation:           workercontracts.PublishV1,
			PathComponents:      published.PathComponents,
			RequestID:           validationRequestID,
			RootID:              published.RootID,
			SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
			Status:              workercontracts.Ok,
		},
	})
	if err != nil {
		return fmt.Errorf("validate stored published artifact: %w", err)
	}
	return nil
}

func validateFailure(failure StageFailure) error {
	_, err := workercontracts.EncodeStageJoinResponse(workercontracts.StageJoinResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.StageJoinFailureResponseV1{
			Operation:     workercontracts.StageJoinV1,
			Reason:        failure.Reason,
			RequestID:     validationRequestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status:        workercontracts.Failed,
		},
	})
	if err != nil {
		return fmt.Errorf("validate stored join failure: %w", err)
	}
	return nil
}

func cloneExecution(execution Execution) Execution {
	execution.Specification.Parts = cloneParts(execution.Specification.Parts)
	if execution.Staged != nil {
		staged := *execution.Staged
		execution.Staged = &staged
	}
	if execution.Published != nil {
		published := *execution.Published
		published.PathComponents = append([]string(nil), published.PathComponents...)
		execution.Published = &published
	}
	if execution.Failure != nil {
		failure := *execution.Failure
		execution.Failure = &failure
	}
	return execution
}

func cloneParts(parts []Part) []Part {
	cloned := make([]Part, len(parts))
	for index, part := range parts {
		cloned[index] = part
		cloned[index].PathComponents = append([]string(nil), part.PathComponents...)
	}
	return cloned
}

package casestore

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"reflect"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/joinverification"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

const (
	JoinExecutionVersionV2 = "radarr-repair-join/v2"
	joinExecutionDomain    = "radarr-repair-join-execution-v1\x00"
)

type JoinExecutionState string

const (
	JoinPrepared        JoinExecutionState = "join_prepared"
	JoinArtifactReady   JoinExecutionState = "artifact_ready"
	JoinDiscardPending  JoinExecutionState = "artifact_discard_pending"
	JoinPublished       JoinExecutionState = "artifact_published"
	JoinDiscarded       JoinExecutionState = "artifact_discarded"
	JoinFailed          JoinExecutionState = "join_failed"
	JoinImportPrepared  JoinExecutionState = "import_prepared"
	JoinImportRequested JoinExecutionState = "import_requested"
	JoinImported        JoinExecutionState = "imported"
	JoinImportFailed    JoinExecutionState = "import_failed"
)

type JoinExecution struct {
	Version       string                        `json:"version"`
	ExecutionID   string                        `json:"execution_id"`
	Authorization decisionpolicy.AuthorizedJoin `json:"authorization"`
	State         JoinExecutionState            `json:"state"`
	PreparedAt    time.Time                     `json:"prepared_at"`
	UpdatedAt     time.Time                     `json:"updated_at"`
	Stage         *JoinStage                    `json:"stage,omitempty"`
	Artifact      *JoinArtifact                 `json:"artifact,omitempty"`
	Published     *JoinPublishedArtifact        `json:"published,omitempty"`
	Failure       *JoinFailure                  `json:"failure,omitempty"`
	Import        *JoinImport                   `json:"import,omitempty"`
	Confirmation  *RadarrImportConfirmation     `json:"confirmation,omitempty"`
}

type JoinStage struct {
	Rejections []joinverification.RejectionReason `json:"rejections"`
}

type JoinArtifact struct {
	ID          string `json:"id"`
	Fingerprint string `json:"fingerprint"`
	SizeBytes   int64  `json:"size_bytes"`
}

type JoinPublishedArtifact struct {
	RootID         string   `json:"root_id"`
	PathComponents []string `json:"path_components"`
}

type JoinFailure struct {
	Operation string `json:"operation"`
	Reason    string `json:"reason"`
}

func EncodeJoinExecution(record JoinExecution) ([]byte, error) {
	if err := validateJoinExecution(record); err != nil {
		return nil, err
	}
	data, err := json.Marshal(record)
	if err != nil {
		return nil, fmt.Errorf("encode join execution: %w", err)
	}
	return data, nil
}

func DecodeJoinExecution(data []byte) (JoinExecution, error) {
	var record JoinExecution
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return JoinExecution{}, fmt.Errorf("decode join execution: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return JoinExecution{}, fmt.Errorf("decode join execution: multiple JSON values")
		}
		return JoinExecution{}, fmt.Errorf("decode join execution trailing JSON: %w", err)
	}
	if err := validateJoinExecution(record); err != nil {
		return JoinExecution{}, err
	}
	return cloneJoinExecution(record), nil
}

func (store *Store) GetJoinExecution(caseID string) (JoinExecution, bool, error) {
	path, err := store.executionPath(caseID)
	if err != nil {
		return JoinExecution{}, false, err
	}
	record, found, err := readJoinExecution(path)
	if err != nil {
		return JoinExecution{}, false, err
	}
	if found && record.Authorization.CaseID != caseID {
		return JoinExecution{}, false, fmt.Errorf(
			"stored join execution has unexpected case ID %q",
			record.Authorization.CaseID,
		)
	}
	return record, found, nil
}

func (store *Store) PrepareJoin(
	authorized decisionpolicy.AuthorizedJoin,
	preparedAt time.Time,
) (JoinExecution, bool, error) {
	if preparedAt.IsZero() {
		return JoinExecution{}, false, fmt.Errorf("join preparation time is required")
	}
	path, err := store.executionPath(authorized.CaseID)
	if err != nil {
		return JoinExecution{}, false, err
	}
	lock, err := store.lock()
	if err != nil {
		return JoinExecution{}, false, err
	}
	defer unlock(lock)

	if err := store.validateJoinAuthorization(authorized); err != nil {
		return JoinExecution{}, false, err
	}
	previous, found, err := readJoinExecution(path)
	if err != nil {
		return JoinExecution{}, false, err
	}
	if found {
		if reflect.DeepEqual(previous.Authorization, authorized) {
			return previous, false, nil
		}
		return JoinExecution{}, false, fmt.Errorf(
			"case %q is already bound to a different join",
			authorized.CaseID,
		)
	}
	executionID, err := JoinExecutionID(authorized)
	if err != nil {
		return JoinExecution{}, false, err
	}
	record := JoinExecution{
		Version:       JoinExecutionVersionV2,
		ExecutionID:   executionID,
		Authorization: cloneJoinAuthorization(authorized),
		State:         JoinPrepared,
		PreparedAt:    preparedAt.UTC(),
		UpdatedAt:     preparedAt.UTC(),
	}
	if err := store.writeJoinExecution(path, record); err != nil {
		return JoinExecution{}, false, err
	}
	return record, true, nil
}

func (store *Store) RecordJoinStage(
	authorized decisionpolicy.AuthorizedJoin,
	request workercontracts.StageJoinRequestV1,
	response workercontracts.StageJoinResponseV1,
	updatedAt time.Time,
) (JoinExecution, bool, error) {
	if _, err := workercontracts.EncodeStageJoinRequest(request); err != nil {
		return JoinExecution{}, false, fmt.Errorf("encode staged join request: %w", err)
	}
	if _, err := workercontracts.EncodeStageJoinResponse(response); err != nil {
		return JoinExecution{}, false, fmt.Errorf("encode staged join response: %w", err)
	}
	validation := joinverification.ValidateStagedJoin(authorized, request, response)
	if hasJoinRejection(validation, joinverification.StageRequestNotAuthorized) ||
		hasJoinRejection(validation, joinverification.StageResponseNotCorrelated) {
		return JoinExecution{}, false, fmt.Errorf(
			"staged join exchange does not match its authorization",
		)
	}
	state, stage, artifact, failure, err := joinStageOutcome(response, validation)
	if err != nil {
		return JoinExecution{}, false, err
	}

	return store.updateJoinExecution(
		authorized.CaseID,
		updatedAt,
		func(previous JoinExecution) (JoinExecution, bool, error) {
			if !reflect.DeepEqual(previous.Authorization, authorized) ||
				request.ExecutionID != previous.ExecutionID {
				return JoinExecution{}, false, fmt.Errorf(
					"staged join does not match the prepared operation",
				)
			}
			if previous.Stage != nil {
				if reflect.DeepEqual(previous.Stage, stage) &&
					reflect.DeepEqual(previous.Artifact, artifact) &&
					(state != JoinFailed || reflect.DeepEqual(previous.Failure, failure)) {
					return previous, false, nil
				}
				return JoinExecution{}, false, fmt.Errorf(
					"join already has a different staged result",
				)
			}
			if previous.State != JoinPrepared {
				return JoinExecution{}, false, fmt.Errorf(
					"cannot record staged join from state %q",
					previous.State,
				)
			}
			previous.State = state
			previous.Stage = stage
			previous.Artifact = artifact
			previous.Failure = failure
			return previous, true, nil
		},
	)
}

func (store *Store) RecordJoinPublish(
	caseID string,
	response workercontracts.PublishResponseV1,
	updatedAt time.Time,
) (JoinExecution, bool, error) {
	if _, err := workercontracts.EncodePublishResponse(response); err != nil {
		return JoinExecution{}, false, fmt.Errorf("encode join publish response: %w", err)
	}
	return store.updateJoinExecution(
		caseID,
		updatedAt,
		func(previous JoinExecution) (JoinExecution, bool, error) {
			if previous.State == JoinPublished {
				if response.Kind == workercontracts.ProbeResponseSucceeded &&
					publishedResultMatches(previous, response) {
					return previous, false, nil
				}
				return JoinExecution{}, false, fmt.Errorf("join already has a different publish result")
			}
			if repeatedJoinFailure(previous, string(workercontracts.PublishV1), response) {
				return previous, false, nil
			}
			if previous.State != JoinArtifactReady || previous.Artifact == nil {
				return JoinExecution{}, false, fmt.Errorf(
					"cannot publish join from state %q",
					previous.State,
				)
			}
			if response.Kind == workercontracts.ProbeResponseFailed {
				previous.State = JoinFailed
				previous.Failure = &JoinFailure{
					Operation: string(workercontracts.PublishV1),
					Reason:    string(response.Failure.Reason),
				}
				return previous, true, nil
			}
			if !publishedArtifactMatches(*previous.Artifact, response) {
				return JoinExecution{}, false, fmt.Errorf(
					"published artifact does not match the verified artifact",
				)
			}
			previous.State = JoinPublished
			previous.Published = &JoinPublishedArtifact{
				RootID: response.Success.RootID,
				PathComponents: append(
					[]string(nil),
					response.Success.PathComponents...,
				),
			}
			return previous, true, nil
		},
	)
}

func (store *Store) RecordJoinDiscard(
	caseID string,
	response workercontracts.DiscardResponseV1,
	updatedAt time.Time,
) (JoinExecution, bool, error) {
	if _, err := workercontracts.EncodeDiscardResponse(response); err != nil {
		return JoinExecution{}, false, fmt.Errorf("encode join discard response: %w", err)
	}
	return store.updateJoinExecution(
		caseID,
		updatedAt,
		func(previous JoinExecution) (JoinExecution, bool, error) {
			if previous.State == JoinDiscarded {
				if response.Kind == workercontracts.ProbeResponseSucceeded &&
					discardedArtifactMatches(*previous.Artifact, response) {
					return previous, false, nil
				}
				return JoinExecution{}, false, fmt.Errorf("join already has a different discard result")
			}
			if repeatedJoinFailure(previous, string(workercontracts.DiscardV1), response) {
				return previous, false, nil
			}
			if previous.State != JoinDiscardPending || previous.Artifact == nil {
				return JoinExecution{}, false, fmt.Errorf(
					"cannot discard join from state %q",
					previous.State,
				)
			}
			if response.Kind == workercontracts.ProbeResponseFailed {
				previous.State = JoinFailed
				previous.Failure = &JoinFailure{
					Operation: string(workercontracts.DiscardV1),
					Reason:    string(response.Failure.Reason),
				}
				return previous, true, nil
			}
			if !discardedArtifactMatches(*previous.Artifact, response) {
				return JoinExecution{}, false, fmt.Errorf(
					"discarded artifact does not match the rejected artifact",
				)
			}
			previous.State = JoinDiscarded
			return previous, true, nil
		},
	)
}

func (store *Store) updateJoinExecution(
	caseID string,
	updatedAt time.Time,
	update func(JoinExecution) (JoinExecution, bool, error),
) (JoinExecution, bool, error) {
	if updatedAt.IsZero() {
		return JoinExecution{}, false, fmt.Errorf("join update time is required")
	}
	path, err := store.executionPath(caseID)
	if err != nil {
		return JoinExecution{}, false, err
	}
	lock, err := store.lock()
	if err != nil {
		return JoinExecution{}, false, err
	}
	defer unlock(lock)

	previous, found, err := readJoinExecution(path)
	if err != nil {
		return JoinExecution{}, false, err
	}
	if !found {
		return JoinExecution{}, false, fmt.Errorf("join for case %q is not prepared", caseID)
	}
	if previous.Authorization.CaseID != caseID {
		return JoinExecution{}, false, fmt.Errorf(
			"stored join execution has unexpected case ID %q",
			previous.Authorization.CaseID,
		)
	}
	if updatedAt.Before(previous.UpdatedAt) {
		return JoinExecution{}, false, fmt.Errorf("join update time moved backwards")
	}
	record, changed, err := update(previous)
	if err != nil || !changed {
		return record, changed, err
	}
	record.UpdatedAt = updatedAt.UTC()
	if err := store.writeJoinExecution(path, record); err != nil {
		return JoinExecution{}, false, err
	}
	return record, true, nil
}

func (store *Store) validateJoinAuthorization(authorized decisionpolicy.AuthorizedJoin) error {
	planned, err := store.GetPlannedCase(authorized.CaseID)
	if err != nil {
		return err
	}
	validation := decisionpolicy.ValidateJoin(planned.Assembly, planned.Decision)
	if !validation.Accepted() || validation.Authorized == nil ||
		!reflect.DeepEqual(*validation.Authorized, authorized) {
		return fmt.Errorf("join authorization does not match stored case and decision")
	}
	return nil
}

func (store *Store) writeJoinExecution(path string, record JoinExecution) error {
	data, err := EncodeJoinExecution(record)
	if err != nil {
		return err
	}
	return replacePrivateFile(store.executionDir, path, data)
}

func readJoinExecution(path string) (JoinExecution, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return JoinExecution{}, false, nil
	}
	if err != nil {
		return JoinExecution{}, false, fmt.Errorf("read join execution: %w", err)
	}
	record, err := DecodeJoinExecution(data)
	if err != nil {
		return JoinExecution{}, true, fmt.Errorf("validate stored join execution: %w", err)
	}
	return record, true, nil
}

func validateJoinExecution(record JoinExecution) error {
	if record.Version != JoinExecutionVersionV2 {
		return fmt.Errorf("unsupported join execution version %q", record.Version)
	}
	if _, err := caseDigest(record.Authorization.CaseID); err != nil {
		return err
	}
	if err := validateJoinAuthorizationShape(record.Authorization); err != nil {
		return err
	}
	executionID, err := JoinExecutionID(record.Authorization)
	if err != nil {
		return err
	}
	if record.ExecutionID != executionID {
		return fmt.Errorf("join execution ID does not match its authorization")
	}
	if record.PreparedAt.IsZero() || record.UpdatedAt.IsZero() ||
		record.UpdatedAt.Before(record.PreparedAt) {
		return fmt.Errorf("join execution times are invalid")
	}
	if record.State == JoinPrepared {
		if record.Stage != nil || record.Artifact != nil ||
			record.Published != nil || record.Failure != nil ||
			record.Import != nil || record.Confirmation != nil {
			return fmt.Errorf("prepared join contains result evidence")
		}
		return nil
	}
	if record.Stage == nil {
		return fmt.Errorf("join result lacks stage verification")
	}
	if record.State == JoinFailed && record.Failure == nil {
		return fmt.Errorf("failed join lacks failure evidence")
	}
	if record.State != JoinFailed && record.Failure != nil {
		return fmt.Errorf("non-failed join contains failure evidence")
	}
	if record.Failure != nil {
		if err := validateJoinFailure(*record.Failure); err != nil {
			return err
		}
	}

	hasRejections := len(record.Stage.Rejections) != 0
	switch record.State {
	case JoinArtifactReady:
		return requireJoinBeforeImport(record, false, false)
	case JoinDiscardPending, JoinDiscarded:
		return requireJoinBeforeImport(record, true, false)
	case JoinPublished:
		return requireJoinBeforeImport(record, false, true)
	case JoinImportPrepared:
		return requireJoinImport(record, false, false)
	case JoinImportRequested:
		return requireJoinImport(record, true, false)
	case JoinImported:
		return requireJoinImport(record, false, true)
	case JoinImportFailed:
		return requireJoinImport(record, true, false)
	case JoinFailed:
		switch record.Failure.Operation {
		case string(workercontracts.StageJoinV1):
			if record.Artifact != nil || record.Published != nil || !hasRejections ||
				record.Import != nil || record.Confirmation != nil {
				return fmt.Errorf("failed staging record is inconsistent")
			}
		case string(workercontracts.PublishV1):
			return requireJoinBeforeImport(record, false, false)
		case string(workercontracts.DiscardV1):
			return requireJoinBeforeImport(record, true, false)
		}
	default:
		return fmt.Errorf("unknown join execution state %q", record.State)
	}
	return nil
}

func requireJoinBeforeImport(record JoinExecution, rejected, published bool) error {
	if err := requireJoinArtifact(record, rejected, published); err != nil {
		return err
	}
	if record.Import != nil || record.Confirmation != nil {
		return fmt.Errorf("join state contains unexpected Radarr import evidence")
	}
	return nil
}

func requireJoinArtifact(record JoinExecution, rejected, published bool) error {
	if record.Artifact == nil || record.Artifact.ID == "" ||
		record.Artifact.Fingerprint == "" || record.Artifact.SizeBytes <= 0 {
		return fmt.Errorf("join state requires a staged artifact")
	}
	if (len(record.Stage.Rejections) != 0) != rejected {
		return fmt.Errorf("join verification result does not match its state")
	}
	if published {
		if record.Published == nil || !validPublishedArtifact(*record.Artifact, *record.Published) {
			return fmt.Errorf("published join lacks valid destination evidence")
		}
	} else if record.Published != nil {
		return fmt.Errorf("unpublished join contains destination evidence")
	}
	return nil
}

func validateJoinAuthorizationShape(authorized decisionpolicy.AuthorizedJoin) error {
	parts := make([]workercontracts.StageJoinPartV1, len(authorized.OrderedParts))
	for position, part := range authorized.OrderedParts {
		parts[position] = workercontracts.StageJoinPartV1{
			ExpectedFingerprint: part.Fingerprint.Fingerprint(),
			FileID:              string(part.FileID),
			PathComponents:      []string{"part.mkv"},
		}
	}
	_, err := workercontracts.EncodeStageJoinRequest(workercontracts.StageJoinRequestV1{
		CapabilityID:        authorized.CapabilityID,
		CaseID:              authorized.CaseID,
		DurationToleranceMS: authorized.DurationToleranceMS,
		ExecutionID:         "execution:validation",
		ExpectedDurationMS:  authorized.ExpectedDurationMS,
		ExpectedSourceBytes: authorized.SourceBytes,
		ExpectedStreamCount: int64(len(authorized.ExpectedStreamLayout.Streams)),
		Operation:           workercontracts.StageJoinV1,
		OutputContainer:     workercontracts.OutputContainer(authorized.OutputContainer),
		Parts:               parts,
		RequestID:           "request:validation",
		RootID:              "root:validation",
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
	})
	if err != nil {
		return fmt.Errorf("join authorization is invalid: %w", err)
	}
	return nil
}

func validateJoinFailure(failure JoinFailure) error {
	var err error
	switch failure.Operation {
	case string(workercontracts.StageJoinV1):
		_, err = workercontracts.EncodeStageJoinResponse(workercontracts.StageJoinResponseV1{
			Kind: workercontracts.ProbeResponseFailed,
			Failure: &workercontracts.StageJoinFailureResponseV1{
				Operation: workercontracts.StageJoinV1,
				Reason:    workercontracts.StageJoinFailureReason(failure.Reason),
				RequestID: "request:stored", SchemaVersion: workercontracts.RadarrRepairWorkerV1,
				Status: workercontracts.Failed,
			},
		})
	case string(workercontracts.PublishV1):
		_, err = workercontracts.EncodePublishResponse(workercontracts.PublishResponseV1{
			Kind: workercontracts.ProbeResponseFailed,
			Failure: &workercontracts.PublishFailureResponseV1{
				Operation: workercontracts.PublishV1,
				Reason:    workercontracts.PublishFailureReason(failure.Reason),
				RequestID: "request:stored", SchemaVersion: workercontracts.RadarrRepairWorkerV1,
				Status: workercontracts.Failed,
			},
		})
	case string(workercontracts.DiscardV1):
		_, err = workercontracts.EncodeDiscardResponse(workercontracts.DiscardResponseV1{
			Kind: workercontracts.ProbeResponseFailed,
			Failure: &workercontracts.DiscardFailureResponseV1{
				Operation: workercontracts.DiscardV1,
				Reason:    workercontracts.DiscardFailureReason(failure.Reason),
				RequestID: "request:stored", SchemaVersion: workercontracts.RadarrRepairWorkerV1,
				Status: workercontracts.Failed,
			},
		})
	default:
		return fmt.Errorf("unknown failed join operation %q", failure.Operation)
	}
	if err != nil {
		return fmt.Errorf("join failure is invalid: %w", err)
	}
	return nil
}

func joinStageOutcome(
	response workercontracts.StageJoinResponseV1,
	validation joinverification.Validation,
) (JoinExecutionState, *JoinStage, *JoinArtifact, *JoinFailure, error) {
	stage := &JoinStage{Rejections: joinRejectionReasons(validation)}
	if response.Kind == workercontracts.ProbeResponseFailed {
		return JoinFailed, stage, nil, &JoinFailure{
			Operation: string(workercontracts.StageJoinV1),
			Reason:    string(response.Failure.Reason),
		}, nil
	}
	if response.Success == nil {
		return "", nil, nil, nil, fmt.Errorf("successful staged join lacks an artifact")
	}
	artifact := &JoinArtifact{
		ID: response.Success.ArtifactID, Fingerprint: response.Success.ArtifactFingerprint,
		SizeBytes: response.Success.SizeBytes,
	}
	if validation.Accepted() {
		return JoinArtifactReady, stage, artifact, nil, nil
	}
	if validation.Discard != nil {
		return JoinDiscardPending, stage, artifact, nil, nil
	}
	return "", nil, nil, nil, fmt.Errorf(
		"staged join produced neither publish nor discard authorization",
	)
}

func repeatedJoinFailure[T interface {
	workercontracts.PublishResponseV1 | workercontracts.DiscardResponseV1
}](previous JoinExecution, operation string, response T) bool {
	if previous.State != JoinFailed || previous.Failure == nil ||
		previous.Failure.Operation != operation {
		return false
	}
	switch typed := any(response).(type) {
	case workercontracts.PublishResponseV1:
		return typed.Failure != nil && previous.Failure.Reason == string(typed.Failure.Reason)
	case workercontracts.DiscardResponseV1:
		return typed.Failure != nil && previous.Failure.Reason == string(typed.Failure.Reason)
	default:
		return false
	}
}

func JoinExecutionID(authorized decisionpolicy.AuthorizedJoin) (string, error) {
	data, err := json.Marshal(authorized)
	if err != nil {
		return "", fmt.Errorf("encode join execution identity: %w", err)
	}
	digest := sha256.New()
	_, _ = digest.Write([]byte(joinExecutionDomain))
	_, _ = digest.Write(data)
	return "execution:" + hex.EncodeToString(digest.Sum(nil)), nil
}

func cloneJoinExecution(record JoinExecution) JoinExecution {
	record.Authorization = cloneJoinAuthorization(record.Authorization)
	if record.Stage != nil {
		rejections := make([]joinverification.RejectionReason, len(record.Stage.Rejections))
		copy(rejections, record.Stage.Rejections)
		record.Stage = &JoinStage{Rejections: rejections}
	}
	if record.Artifact != nil {
		artifact := *record.Artifact
		record.Artifact = &artifact
	}
	if record.Published != nil {
		record.Published = &JoinPublishedArtifact{
			RootID: record.Published.RootID,
			PathComponents: append(
				[]string(nil),
				record.Published.PathComponents...,
			),
		}
	}
	if record.Failure != nil {
		failure := *record.Failure
		record.Failure = &failure
	}
	if record.Import != nil {
		joinImport := *record.Import
		joinImport.Command.File.Languages = append(
			[]controller.RadarrLanguage(nil),
			joinImport.Command.File.Languages...,
		)
		if revision := joinImport.Command.File.Quality.Revision; revision != nil {
			cloned := *revision
			joinImport.Command.File.Quality.Revision = &cloned
		}
		if joinImport.CommandID != nil {
			joinImport.CommandID = int64Pointer(*joinImport.CommandID)
		}
		record.Import = &joinImport
	}
	if record.Confirmation != nil {
		confirmation := *record.Confirmation
		record.Confirmation = &confirmation
	}
	return record
}

func cloneJoinAuthorization(
	authorized decisionpolicy.AuthorizedJoin,
) decisionpolicy.AuthorizedJoin {
	cloned := authorized
	cloned.OrderedParts = append([]decisionpolicy.AuthorizedJoinPart(nil), authorized.OrderedParts...)
	cloned.ExpectedStreamLayout = authorized.ExpectedStreamLayout.Clone()
	return cloned
}

func joinRejectionReasons(
	validation joinverification.Validation,
) []joinverification.RejectionReason {
	reasons := make([]joinverification.RejectionReason, len(validation.Rejections))
	for index, rejection := range validation.Rejections {
		reasons[index] = rejection.Reason
	}
	return reasons
}

func hasJoinRejection(
	validation joinverification.Validation,
	want joinverification.RejectionReason,
) bool {
	for _, rejection := range validation.Rejections {
		if rejection.Reason == want {
			return true
		}
	}
	return false
}

func publishedArtifactMatches(
	artifact JoinArtifact,
	response workercontracts.PublishResponseV1,
) bool {
	return response.Success != nil && response.Success.ArtifactID == artifact.ID &&
		response.Success.ArtifactFingerprint == artifact.Fingerprint
}

func publishedResultMatches(
	record JoinExecution,
	response workercontracts.PublishResponseV1,
) bool {
	return record.Artifact != nil && record.Published != nil && response.Success != nil &&
		publishedArtifactMatches(*record.Artifact, response) &&
		response.Success.RootID == record.Published.RootID &&
		reflect.DeepEqual(response.Success.PathComponents, record.Published.PathComponents)
}

func discardedArtifactMatches(
	artifact JoinArtifact,
	response workercontracts.DiscardResponseV1,
) bool {
	return response.Success != nil && response.Success.ArtifactID == artifact.ID &&
		response.Success.ArtifactFingerprint == artifact.Fingerprint
}

func validPublishedArtifact(artifact JoinArtifact, published JoinPublishedArtifact) bool {
	_, err := workercontracts.EncodePublishResponse(workercontracts.PublishResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.PublishSuccessResponseV1{
			ArtifactFingerprint: artifact.Fingerprint,
			ArtifactID:          artifact.ID,
			Operation:           workercontracts.PublishV1,
			PathComponents:      published.PathComponents,
			RequestID:           "request:stored",
			RootID:              published.RootID,
			SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
			Status:              workercontracts.Ok,
		},
	})
	return err == nil
}

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
	"slices"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/remuxverification"
	"github.com/booxter/nix-config/radarr-repair/internal/repairartifact"
	"github.com/booxter/nix-config/radarr-repair/internal/workerclient"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const (
	RemuxExecutionVersionV1 = "radarr-repair-bluray-remux/v1"
	remuxExecutionDomain    = "radarr-repair-bluray-remux-execution-v1\x00"
)

type RemuxExecutionState string

const (
	RemuxPrepared        RemuxExecutionState = "remux_prepared"
	RemuxStaged          RemuxExecutionState = "artifact_staged"
	RemuxPublished       RemuxExecutionState = "artifact_published"
	RemuxFailed          RemuxExecutionState = "remux_failed"
	RemuxImportPrepared  RemuxExecutionState = "import_prepared"
	RemuxImportRequested RemuxExecutionState = "import_requested"
	RemuxImported        RemuxExecutionState = "imported"
	RemuxImportFailed    RemuxExecutionState = "import_failed"
)

type RemuxArtifact struct {
	ID          string `json:"id"`
	Fingerprint string `json:"fingerprint"`
	SizeBytes   int64  `json:"size_bytes"`
}

type RemuxPublishedArtifact struct {
	RootID         string   `json:"root_id"`
	PathComponents []string `json:"path_components"`
}

type RemuxFailure struct {
	Operation string `json:"operation"`
	Reason    string `json:"reason"`
}

type RemuxExecution struct {
	Version       string                                `json:"version"`
	ExecutionID   string                                `json:"execution_id"`
	Authorization decisionpolicy.AuthorizedRemux        `json:"authorization"`
	State         RemuxExecutionState                   `json:"state"`
	PreparedAt    time.Time                             `json:"prepared_at"`
	UpdatedAt     time.Time                             `json:"updated_at"`
	StageRequest  *workercontracts.BlurayRemuxRequestV1 `json:"stage_request,omitempty"`
	Artifact      *RemuxArtifact                        `json:"artifact,omitempty"`
	Published     *RemuxPublishedArtifact               `json:"published,omitempty"`
	Failure       *RemuxFailure                         `json:"failure,omitempty"`
	Import        *JoinImport                           `json:"import,omitempty"`
	Confirmation  *RadarrImportConfirmation             `json:"confirmation,omitempty"`
}

func RemuxExecutionID(authorized decisionpolicy.AuthorizedRemux) (string, error) {
	if err := validateRemuxAuthorizationShape(authorized); err != nil {
		return "", err
	}
	data, err := json.Marshal(authorized)
	if err != nil {
		return "", fmt.Errorf("encode remux execution identity: %w", err)
	}
	digest := sha256.New()
	_, _ = digest.Write([]byte(remuxExecutionDomain))
	_, _ = digest.Write(data)
	return "execution:" + hex.EncodeToString(digest.Sum(nil)), nil
}

func EncodeRemuxExecution(record RemuxExecution) ([]byte, error) {
	if err := validateRemuxExecution(record); err != nil {
		return nil, err
	}
	data, err := json.Marshal(record)
	if err != nil {
		return nil, fmt.Errorf("encode remux execution: %w", err)
	}
	return data, nil
}

func DecodeRemuxExecution(data []byte) (RemuxExecution, error) {
	var record RemuxExecution
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return RemuxExecution{}, fmt.Errorf("decode remux execution: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return RemuxExecution{}, fmt.Errorf("remux execution has multiple JSON values")
		}
		return RemuxExecution{}, fmt.Errorf("remux execution has trailing JSON: %w", err)
	}
	if err := validateRemuxExecution(record); err != nil {
		return RemuxExecution{}, err
	}
	return cloneRemuxExecution(record), nil
}

func (store *Store) GetRemuxExecution(caseID string) (RemuxExecution, bool, error) {
	path, err := store.executionPath(caseID)
	if err != nil {
		return RemuxExecution{}, false, err
	}
	record, found, err := readRemuxExecution(path)
	if err != nil {
		return RemuxExecution{}, false, err
	}
	if found && record.Authorization.CaseID != caseID {
		return RemuxExecution{}, false, fmt.Errorf("stored remux has an unexpected case ID")
	}
	return record, found, nil
}

func (store *Store) PrepareRemux(
	authorized decisionpolicy.AuthorizedRemux,
	preparedAt time.Time,
) (RemuxExecution, bool, error) {
	if preparedAt.IsZero() {
		return RemuxExecution{}, false, fmt.Errorf("remux preparation time is required")
	}
	executionID, err := RemuxExecutionID(authorized)
	if err != nil {
		return RemuxExecution{}, false, err
	}
	path, err := store.executionPath(authorized.CaseID)
	if err != nil {
		return RemuxExecution{}, false, err
	}
	lock, err := store.lock()
	if err != nil {
		return RemuxExecution{}, false, err
	}
	defer unlock(lock)
	planned, err := store.GetPlannedCase(authorized.CaseID)
	if err != nil {
		return RemuxExecution{}, false, err
	}
	validation := decisionpolicy.ValidateRemux(planned.Assembly, planned.Decision)
	if !validation.Accepted() || !reflect.DeepEqual(*validation.Authorized, authorized) {
		return RemuxExecution{}, false, fmt.Errorf("remux does not match stored case and decision")
	}
	previous, found, err := readRemuxExecution(path)
	if err != nil {
		return RemuxExecution{}, false, err
	}
	if found {
		if previous.ExecutionID != executionID ||
			!reflect.DeepEqual(previous.Authorization, authorized) {
			return RemuxExecution{}, false, fmt.Errorf("case is bound to a different remux")
		}
		return previous, false, nil
	}
	preparedAt = preparedAt.UTC()
	record := RemuxExecution{
		Version:       RemuxExecutionVersionV1,
		ExecutionID:   executionID,
		Authorization: cloneRemuxAuthorization(authorized),
		State:         RemuxPrepared,
		PreparedAt:    preparedAt,
		UpdatedAt:     preparedAt,
	}
	if err := store.writeRemuxExecution(path, record); err != nil {
		return RemuxExecution{}, false, err
	}
	return record, true, nil
}

func (store *Store) RecordRemuxStage(
	caseID string,
	exchange workerclient.BlurayRemuxExchange,
	updatedAt time.Time,
) (RemuxExecution, bool, error) {
	if _, err := workercontracts.EncodeBlurayRemuxRequest(exchange.Request); err != nil {
		return RemuxExecution{}, false, err
	}
	if _, err := workercontracts.EncodeBlurayRemuxResponse(exchange.Response); err != nil {
		return RemuxExecution{}, false, err
	}
	return store.updateRemuxExecution(caseID, updatedAt, func(previous RemuxExecution) (RemuxExecution, bool, error) {
		if previous.State != RemuxPrepared ||
			!remuxStageMatches(previous, exchange.Request) ||
			exchange.Response.RequestID() != exchange.Request.RequestID {
			return RemuxExecution{}, false, fmt.Errorf("staged Blu-ray remux does not match authorization")
		}
		request := exchange.Request
		previous.StageRequest = &request
		if exchange.Response.Failure != nil {
			previous.State = RemuxFailed
			previous.Failure = &RemuxFailure{
				Operation: string(workercontracts.StageBlurayRemuxV1),
				Reason:    string(exchange.Response.Failure.Reason),
			}
			return previous, true, nil
		}
		success := exchange.Response.Success
		if success == nil {
			return RemuxExecution{}, false, fmt.Errorf("staged remux has no result")
		}
		if err := remuxverification.ValidateOutput(
			previous.Authorization.ExpectedDurationMS,
			int(previous.Authorization.ExpectedChapters),
			previous.Authorization.ExpectedTracks,
			workerclient.EvidenceFromWorker(success.Evidence),
		); err != nil {
			return RemuxExecution{}, false, fmt.Errorf("reject staged Blu-ray output: %w", err)
		}
		previous.State = RemuxStaged
		previous.Artifact = &RemuxArtifact{
			ID:          success.ArtifactID,
			Fingerprint: success.ArtifactFingerprint,
			SizeBytes:   success.SizeBytes,
		}
		return previous, true, nil
	})
}

func (store *Store) RecordRemuxPublish(
	caseID string,
	response workercontracts.BlurayPublishResponseV1,
	updatedAt time.Time,
) (RemuxExecution, bool, error) {
	if _, err := workercontracts.EncodeBlurayPublishResponse(response); err != nil {
		return RemuxExecution{}, false, err
	}
	return store.updateRemuxExecution(caseID, updatedAt, func(previous RemuxExecution) (RemuxExecution, bool, error) {
		if previous.State != RemuxStaged || previous.Artifact == nil || previous.StageRequest == nil {
			return RemuxExecution{}, false, fmt.Errorf("remux is not ready to publish")
		}
		if response.Failure != nil {
			previous.State = RemuxFailed
			previous.Failure = &RemuxFailure{
				Operation: string(workercontracts.PublishBlurayRemuxV1),
				Reason:    string(response.Failure.Reason),
			}
			return previous, true, nil
		}
		success := response.Success
		if success == nil || success.ArtifactID != previous.Artifact.ID ||
			success.ArtifactFingerprint != previous.Artifact.Fingerprint ||
			success.RootID != previous.StageRequest.RootID ||
			!remuxPublishedPathMatches(previous.StageRequest, previous.Artifact.ID, success.PathComponents) {
			return RemuxExecution{}, false, fmt.Errorf("published remux does not match staged artifact")
		}
		previous.State = RemuxPublished
		previous.Published = &RemuxPublishedArtifact{
			RootID:         success.RootID,
			PathComponents: append([]string(nil), success.PathComponents...),
		}
		return previous, true, nil
	})
}

func remuxStageMatches(
	execution RemuxExecution,
	request workercontracts.BlurayRemuxRequestV1,
) bool {
	authorized := execution.Authorization
	if request.ExecutionID != execution.ExecutionID ||
		request.CaseID != authorized.CaseID ||
		request.CapabilityID != authorized.CapabilityID ||
		request.ExpectedDurationMS != authorized.ExpectedDurationMS ||
		request.ExpectedChapterCount != authorized.ExpectedChapters ||
		request.Playlist.ExpectedFingerprint != authorized.Playlist.Fingerprint.Fingerprint() ||
		request.Playlist.SizeBytes != authorized.Playlist.Fingerprint.SizeBytes ||
		len(request.Clips) != len(authorized.Clips) ||
		len(request.ExpectedTracks) != len(authorized.ExpectedTracks) {
		return false
	}
	for index, clip := range authorized.Clips {
		if request.Clips[index].ExpectedFingerprint != clip.Fingerprint.Fingerprint() ||
			request.Clips[index].SizeBytes != clip.Fingerprint.SizeBytes {
			return false
		}
	}
	for index, track := range authorized.ExpectedTracks {
		requested := request.ExpectedTracks[index]
		if string(requested.Kind) != track.Kind || requested.Codec != track.Codec ||
			requested.Language != track.Language {
			return false
		}
	}
	return true
}

func remuxPublishedPathMatches(
	request *workercontracts.BlurayRemuxRequestV1,
	artifactID string,
	path []string,
) bool {
	playlist := request.Playlist.PathComponents
	if len(playlist) < 3 || len(path) != len(playlist)-2 {
		return false
	}
	return slices.Equal(path[:len(path)-1], playlist[:len(playlist)-3]) &&
		path[len(path)-1] == repairartifact.PublishedName(artifactID, ".mkv")
}

func (store *Store) updateRemuxExecution(
	caseID string,
	updatedAt time.Time,
	update func(RemuxExecution) (RemuxExecution, bool, error),
) (RemuxExecution, bool, error) {
	if updatedAt.IsZero() {
		return RemuxExecution{}, false, fmt.Errorf("remux update time is required")
	}
	path, err := store.executionPath(caseID)
	if err != nil {
		return RemuxExecution{}, false, err
	}
	lock, err := store.lock()
	if err != nil {
		return RemuxExecution{}, false, err
	}
	defer unlock(lock)
	previous, found, err := readRemuxExecution(path)
	if err != nil {
		return RemuxExecution{}, false, err
	}
	if !found || previous.Authorization.CaseID != caseID {
		return RemuxExecution{}, false, fmt.Errorf("remux for case is not prepared")
	}
	if updatedAt.Before(previous.UpdatedAt) {
		return RemuxExecution{}, false, fmt.Errorf("remux update time moved backwards")
	}
	next, changed, err := update(previous)
	if err != nil || !changed {
		return next, changed, err
	}
	next.UpdatedAt = updatedAt.UTC()
	if err := store.writeRemuxExecution(path, next); err != nil {
		return RemuxExecution{}, false, err
	}
	return next, true, nil
}

func validateRemuxExecution(record RemuxExecution) error {
	if record.Version != RemuxExecutionVersionV1 {
		return fmt.Errorf("unsupported remux execution version")
	}
	identity, err := RemuxExecutionID(record.Authorization)
	if err != nil {
		return fmt.Errorf("remux execution identity is invalid: %w", err)
	}
	if record.ExecutionID != identity {
		return fmt.Errorf("remux execution identity does not match authorization")
	}
	if record.PreparedAt.IsZero() || record.UpdatedAt.IsZero() ||
		record.UpdatedAt.Before(record.PreparedAt) {
		return fmt.Errorf("remux execution timestamps are invalid")
	}
	switch record.State {
	case RemuxPrepared:
		if record.StageRequest != nil || record.Artifact != nil ||
			record.Published != nil || record.Failure != nil ||
			record.Import != nil || record.Confirmation != nil {
			return fmt.Errorf("prepared remux has result evidence")
		}
	case RemuxStaged, RemuxPublished:
		if record.StageRequest == nil || record.Artifact == nil ||
			record.Failure != nil || record.Artifact.ID == "" ||
			record.Artifact.Fingerprint == "" || record.Artifact.SizeBytes <= 0 ||
			!remuxStageMatches(record, *record.StageRequest) {
			return fmt.Errorf("remux staging evidence is invalid")
		}
		if _, err := workercontracts.EncodeBlurayRemuxRequest(*record.StageRequest); err != nil {
			return fmt.Errorf("remux stage request is invalid: %w", err)
		}
		if record.State == RemuxStaged && record.Published != nil {
			return fmt.Errorf("unpublished remux has a destination")
		}
		if record.State == RemuxPublished && (record.Published == nil ||
			record.Published.RootID != record.StageRequest.RootID ||
			!remuxPublishedPathMatches(record.StageRequest, record.Artifact.ID, record.Published.PathComponents)) {
			return fmt.Errorf("published remux destination is invalid")
		}
		if record.Import != nil || record.Confirmation != nil {
			return fmt.Errorf("remux has unexpected import evidence")
		}
	case RemuxFailed:
		if record.Failure == nil || record.Published != nil ||
			record.Import != nil || record.Confirmation != nil {
			return fmt.Errorf("failed remux has inconsistent evidence")
		}
		if record.Failure.Reason == "" || record.StageRequest == nil ||
			!remuxStageMatches(record, *record.StageRequest) {
			return fmt.Errorf("failed remux lacks stage evidence")
		}
		if _, err := workercontracts.EncodeBlurayRemuxRequest(*record.StageRequest); err != nil {
			return fmt.Errorf("failed remux stage request is invalid: %w", err)
		}
		switch record.Failure.Operation {
		case string(workercontracts.StageBlurayRemuxV1):
			if record.Artifact != nil {
				return fmt.Errorf("failed remux stage has artifact")
			}
		case string(workercontracts.PublishBlurayRemuxV1):
			if record.Artifact == nil || record.Artifact.ID == "" ||
				record.Artifact.Fingerprint == "" || record.Artifact.SizeBytes <= 0 {
				return fmt.Errorf("failed remux publish lacks artifact")
			}
		default:
			return fmt.Errorf("unknown failed remux operation")
		}
	case RemuxImportPrepared, RemuxImportRequested, RemuxImported, RemuxImportFailed:
		if record.StageRequest == nil || record.Artifact == nil || record.Published == nil ||
			record.Artifact.ID == "" || record.Artifact.Fingerprint == "" ||
			record.Artifact.SizeBytes <= 0 || record.Failure != nil ||
			!remuxStageMatches(record, *record.StageRequest) ||
			!remuxPublishedPathMatches(record.StageRequest, record.Artifact.ID, record.Published.PathComponents) ||
			record.Published.RootID != record.StageRequest.RootID || record.Import == nil {
			return fmt.Errorf("remux import lacks published artifact")
		}
		if _, err := workercontracts.EncodeBlurayRemuxRequest(*record.StageRequest); err != nil {
			return fmt.Errorf("remux import stage request is invalid: %w", err)
		}
		if err := validateStoredJoinImport(*record.Import, record.PreparedAt, record.UpdatedAt); err != nil {
			return err
		}
		if record.State == RemuxImportPrepared && record.Import.CommandID != nil {
			return fmt.Errorf("prepared remux import has a command ID")
		}
		if (record.State == RemuxImportRequested || record.State == RemuxImportFailed) &&
			record.Import.CommandID == nil {
			return fmt.Errorf("requested remux import lacks a command ID")
		}
		if record.State == RemuxImported {
			if record.Confirmation == nil || validateRadarrImportConfirmation(*record.Confirmation) != nil {
				return fmt.Errorf("imported remux lacks confirmation")
			}
		} else if record.Confirmation != nil {
			return fmt.Errorf("unconfirmed remux has import confirmation")
		}
	default:
		return fmt.Errorf("unknown remux execution state %q", record.State)
	}
	return nil
}

func validateRemuxAuthorizationShape(authorized decisionpolicy.AuthorizedRemux) error {
	if _, err := caseDigest(authorized.CaseID); err != nil {
		return err
	}
	if authorized.CapabilityID == "" || authorized.Playlist.FileID == "" ||
		authorized.Playlist.Fingerprint.SizeBytes <= 0 ||
		len(authorized.Clips) == 0 || authorized.SourceBytes <= 0 ||
		authorized.ExpectedDurationMS <= 0 || authorized.ExpectedChapters < 0 ||
		len(authorized.ExpectedTracks) == 0 {
		return fmt.Errorf("remux authorization is incomplete")
	}
	var sourceBytes int64
	for _, clip := range authorized.Clips {
		if clip.FileID == "" || clip.Fingerprint.SizeBytes <= 0 ||
			clip.Fingerprint.SizeBytes > authorized.SourceBytes-sourceBytes {
			return fmt.Errorf("remux clip authorization is invalid")
		}
		sourceBytes += clip.Fingerprint.SizeBytes
	}
	if sourceBytes != authorized.SourceBytes {
		return fmt.Errorf("remux source size does not match clips")
	}
	return nil
}

func cloneRemuxAuthorization(authorized decisionpolicy.AuthorizedRemux) decisionpolicy.AuthorizedRemux {
	authorized.Clips = append([]decisionpolicy.AuthorizedRemuxFile(nil), authorized.Clips...)
	authorized.ExpectedTracks = slices.Clone(authorized.ExpectedTracks)
	return authorized
}

func cloneRemuxExecution(record RemuxExecution) RemuxExecution {
	record.Authorization = cloneRemuxAuthorization(record.Authorization)
	if record.StageRequest != nil {
		request := *record.StageRequest
		request.Playlist.PathComponents = append([]string(nil), request.Playlist.PathComponents...)
		request.Clips = append([]workercontracts.BlurayRemuxSourceV1(nil), request.Clips...)
		for index := range request.Clips {
			request.Clips[index].PathComponents = append([]string(nil), request.Clips[index].PathComponents...)
		}
		request.ExpectedTracks = append([]workercontracts.BlurayRemuxTrackV1(nil), request.ExpectedTracks...)
		record.StageRequest = &request
	}
	if record.Artifact != nil {
		artifact := *record.Artifact
		record.Artifact = &artifact
	}
	if record.Published != nil {
		published := *record.Published
		published.PathComponents = append([]string(nil), published.PathComponents...)
		record.Published = &published
	}
	if record.Failure != nil {
		failure := *record.Failure
		record.Failure = &failure
	}
	if record.Import != nil {
		imported := *record.Import
		if imported.CommandID != nil {
			value := *imported.CommandID
			imported.CommandID = &value
		}
		record.Import = &imported
	}
	if record.Confirmation != nil {
		confirmation := *record.Confirmation
		record.Confirmation = &confirmation
	}
	return record
}

func readRemuxExecution(path string) (RemuxExecution, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return RemuxExecution{}, false, nil
	}
	if err != nil {
		return RemuxExecution{}, false, fmt.Errorf("read remux execution: %w", err)
	}
	record, err := DecodeRemuxExecution(data)
	if err != nil {
		return RemuxExecution{}, true, fmt.Errorf("validate remux execution: %w", err)
	}
	return record, true, nil
}

func (store *Store) writeRemuxExecution(path string, record RemuxExecution) error {
	data, err := EncodeRemuxExecution(record)
	if err != nil {
		return err
	}
	return replacePrivateFile(store.executionDir, path, data)
}

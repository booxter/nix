package casestore

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/remuxverification"
	"github.com/booxter/nix-config/radarr-repair/internal/repairartifact"
	"github.com/booxter/nix-config/radarr-repair/internal/workerclient"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

func DVDExecutionID(authorized decisionpolicy.AuthorizedDVD) (string, error) {
	if err := validateDVDAuthorizationShape(authorized); err != nil {
		return "", err
	}
	data, err := json.Marshal(authorized)
	if err != nil {
		return "", fmt.Errorf("encode DVD execution identity: %w", err)
	}
	digest := sha256.New()
	_, _ = digest.Write([]byte(dvdExecutionDomain))
	_, _ = digest.Write(data)
	return "execution:" + hex.EncodeToString(digest.Sum(nil)), nil
}

func (record RemuxExecution) CaseID() string {
	if record.DVDAuthorization != nil {
		return record.DVDAuthorization.CaseID
	}
	return record.Authorization.CaseID
}

func validateDiscExecution(record RemuxExecution) error {
	if record.Version == DVDExecutionVersionV1 {
		return validateDVDExecution(record)
	}
	return validateRemuxExecution(record)
}

func (store *Store) PrepareDVD(
	authorized decisionpolicy.AuthorizedDVD, preparedAt time.Time,
) (RemuxExecution, bool, error) {
	if preparedAt.IsZero() {
		return RemuxExecution{}, false, fmt.Errorf("DVD preparation time is required")
	}
	executionID, err := DVDExecutionID(authorized)
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
	validation := decisionpolicy.ValidateDVD(planned.Assembly, planned.Decision)
	if !validation.Accepted() || !reflect.DeepEqual(*validation.Authorized, authorized) {
		return RemuxExecution{}, false, fmt.Errorf("DVD remux does not match stored case and decision")
	}
	previous, found, err := readRemuxExecution(path)
	if err != nil {
		return RemuxExecution{}, false, err
	}
	if found {
		if previous.Version != DVDExecutionVersionV1 || previous.ExecutionID != executionID ||
			previous.DVDAuthorization == nil || !reflect.DeepEqual(*previous.DVDAuthorization, authorized) {
			return RemuxExecution{}, false, fmt.Errorf("case is bound to a different repair")
		}
		return previous, false, nil
	}
	preparedAt = preparedAt.UTC()
	copy := authorized
	copy.Sources = slices.Clone(authorized.Sources)
	copy.ExpectedTracks = slices.Clone(authorized.ExpectedTracks)
	record := RemuxExecution{
		Version: DVDExecutionVersionV1, ExecutionID: executionID,
		DVDAuthorization: &copy, State: RemuxPrepared,
		PreparedAt: preparedAt, UpdatedAt: preparedAt,
	}
	if err := store.writeRemuxExecution(path, record); err != nil {
		return RemuxExecution{}, false, err
	}
	return record, true, nil
}

func (store *Store) RecordDVDStage(
	caseID string, exchange workerclient.DVDRemuxExchange, at time.Time,
) (RemuxExecution, bool, error) {
	if _, err := workercontracts.EncodeDVDRemuxRequest(exchange.Request); err != nil {
		return RemuxExecution{}, false, err
	}
	if _, err := workercontracts.EncodeDVDRemuxResponse(exchange.Response); err != nil {
		return RemuxExecution{}, false, err
	}
	return store.updateRemuxExecution(caseID, at, func(previous RemuxExecution) (RemuxExecution, bool, error) {
		if previous.Version != DVDExecutionVersionV1 || previous.State != RemuxPrepared ||
			!dvdStageMatches(previous, exchange.Request) ||
			exchange.Response.RequestID() != exchange.Request.RequestID {
			return RemuxExecution{}, false, fmt.Errorf("staged DVD remux does not match authorization")
		}
		request := exchange.Request
		previous.DVDStageRequest = &request
		if failure := exchange.Response.Failure; failure != nil {
			previous.State = RemuxFailed
			previous.Failure = &RemuxFailure{
				Operation: string(workercontracts.StageDVDRemuxV1), Reason: string(failure.Reason),
			}
			return previous, true, nil
		}
		success := exchange.Response.Success
		if success == nil {
			return RemuxExecution{}, false, fmt.Errorf("staged DVD remux has no result")
		}
		authorized := previous.DVDAuthorization
		if err := remuxverification.ValidateDVDOutput(
			authorized.ExpectedDurationMS, authorized.ExpectedChapters,
			authorized.ExpectedTracks, workerclient.EvidenceFromWorker(success.Evidence),
		); err != nil {
			return RemuxExecution{}, false, fmt.Errorf("reject staged DVD output: %w", err)
		}
		previous.State = RemuxStaged
		previous.Artifact = &RemuxArtifact{
			ID: success.ArtifactID, Fingerprint: success.ArtifactFingerprint,
			SizeBytes: success.SizeBytes,
		}
		return previous, true, nil
	})
}

func (store *Store) RecordDVDPublish(
	caseID string, response workercontracts.DVDPublishResponseV1, at time.Time,
) (RemuxExecution, bool, error) {
	if _, err := workercontracts.EncodeDVDPublishResponse(response); err != nil {
		return RemuxExecution{}, false, err
	}
	return store.updateRemuxExecution(caseID, at, func(previous RemuxExecution) (RemuxExecution, bool, error) {
		if previous.Version != DVDExecutionVersionV1 || previous.State != RemuxStaged ||
			previous.Artifact == nil || previous.DVDStageRequest == nil {
			return RemuxExecution{}, false, fmt.Errorf("DVD remux is not ready to publish")
		}
		if failure := response.Failure; failure != nil {
			previous.State = RemuxFailed
			previous.Failure = &RemuxFailure{
				Operation: string(workercontracts.PublishDVDRemuxV1), Reason: string(failure.Reason),
			}
			return previous, true, nil
		}
		success := response.Success
		if success == nil || success.ArtifactID != previous.Artifact.ID ||
			success.ArtifactFingerprint != previous.Artifact.Fingerprint ||
			success.RootID != previous.DVDStageRequest.RootID ||
			!dvdPublishedPathMatches(previous.DVDStageRequest, previous.Artifact.ID, success.PathComponents) {
			return RemuxExecution{}, false, fmt.Errorf("published DVD remux does not match staged artifact")
		}
		previous.State = RemuxPublished
		previous.Published = &RemuxPublishedArtifact{
			RootID: success.RootID, PathComponents: slices.Clone(success.PathComponents),
		}
		return previous, true, nil
	})
}

func dvdStageMatches(record RemuxExecution, request workercontracts.DVDRemuxRequestV1) bool {
	authorized := record.DVDAuthorization
	if authorized == nil || request.ExecutionID != record.ExecutionID ||
		request.CaseID != authorized.CaseID || request.CapabilityID != authorized.CapabilityID ||
		request.TitleNumber != int64(authorized.TitleNumber) ||
		request.ExpectedDurationMS != authorized.ExpectedDurationMS ||
		request.ExpectedChapterCount != int64(authorized.ExpectedChapters) ||
		request.Navigation.ExpectedFingerprint != authorized.Navigation.Fingerprint.Fingerprint() ||
		request.Navigation.SizeBytes != authorized.Navigation.Fingerprint.SizeBytes ||
		len(request.Sources) != len(authorized.Sources) ||
		len(request.ExpectedTracks) != len(authorized.ExpectedTracks) {
		return false
	}
	for index, source := range authorized.Sources {
		if request.Sources[index].ExpectedFingerprint != source.Fingerprint.Fingerprint() ||
			request.Sources[index].SizeBytes != source.Fingerprint.SizeBytes {
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

func dvdPublishedPathMatches(
	request *workercontracts.DVDRemuxRequestV1, artifactID string, path []string,
) bool {
	navigation := request.Navigation.PathComponents
	return len(navigation) >= 2 && len(path) == len(navigation)-1 &&
		slices.Equal(path[:len(path)-1], navigation[:len(navigation)-2]) &&
		path[len(path)-1] == repairartifact.PublishedName(artifactID, ".mkv")
}

func validateDVDAuthorizationShape(authorized decisionpolicy.AuthorizedDVD) error {
	if _, err := caseDigest(authorized.CaseID); err != nil {
		return err
	}
	if authorized.CapabilityID == "" || authorized.Navigation.FileID == "" ||
		authorized.Navigation.Fingerprint.SizeBytes <= 0 || len(authorized.Sources) < 3 ||
		authorized.SourceBytes <= 0 || authorized.TitleNumber <= 0 ||
		authorized.ExpectedDurationMS <= 0 || authorized.ExpectedChapters <= 0 ||
		len(authorized.ExpectedTracks) == 0 {
		return fmt.Errorf("DVD authorization is incomplete")
	}
	var sourceBytes int64
	hasNavigation := false
	for _, source := range authorized.Sources {
		if source.FileID == "" || source.Fingerprint.SizeBytes <= 0 ||
			source.Fingerprint.SizeBytes > authorized.SourceBytes-sourceBytes {
			return fmt.Errorf("DVD source authorization is invalid")
		}
		if source.FileID == authorized.Navigation.FileID {
			hasNavigation = true
		}
		sourceBytes += source.Fingerprint.SizeBytes
	}
	if sourceBytes != authorized.SourceBytes || !hasNavigation {
		return fmt.Errorf("DVD source inventory does not match authorization")
	}
	return nil
}

func validateDVDExecution(record RemuxExecution) error {
	if record.DVDAuthorization == nil || record.StageRequest != nil ||
		!reflect.DeepEqual(record.Authorization, decisionpolicy.AuthorizedRemux{}) {
		return fmt.Errorf("DVD remux contains Blu-ray evidence")
	}
	identity, err := DVDExecutionID(*record.DVDAuthorization)
	if err != nil || record.ExecutionID != identity {
		return fmt.Errorf("DVD execution identity does not match authorization")
	}
	if record.PreparedAt.IsZero() || record.UpdatedAt.IsZero() ||
		record.UpdatedAt.Before(record.PreparedAt) {
		return fmt.Errorf("DVD execution timestamps are invalid")
	}
	switch record.State {
	case RemuxPrepared:
		if record.DVDStageRequest != nil || record.Artifact != nil || record.Published != nil ||
			record.Failure != nil || record.Import != nil || record.Confirmation != nil {
			return fmt.Errorf("prepared DVD remux has result evidence")
		}
	case RemuxStaged, RemuxPublished, RemuxFailed,
		RemuxImportPrepared, RemuxImportRequested, RemuxImported, RemuxImportFailed:
		if record.DVDStageRequest == nil || !dvdStageMatches(record, *record.DVDStageRequest) {
			return fmt.Errorf("DVD remux staging evidence is invalid")
		}
		if _, err := workercontracts.EncodeDVDRemuxRequest(*record.DVDStageRequest); err != nil {
			return fmt.Errorf("DVD stage request is invalid: %w", err)
		}
		if record.State == RemuxFailed {
			if record.Failure == nil || record.Failure.Reason == "" || record.Published != nil ||
				record.Import != nil || record.Confirmation != nil {
				return fmt.Errorf("failed DVD remux has inconsistent evidence")
			}
			switch record.Failure.Operation {
			case string(workercontracts.StageDVDRemuxV1):
				if record.Artifact != nil {
					return fmt.Errorf("failed DVD stage has artifact")
				}
			case string(workercontracts.PublishDVDRemuxV1):
				if !validRemuxArtifact(record.Artifact) {
					return fmt.Errorf("failed DVD publish lacks artifact")
				}
			default:
				return fmt.Errorf("unknown failed DVD operation")
			}
			return nil
		}
		if record.Failure != nil || !validRemuxArtifact(record.Artifact) {
			return fmt.Errorf("DVD artifact evidence is invalid")
		}
		if record.State == RemuxStaged {
			if record.Published != nil || record.Import != nil || record.Confirmation != nil {
				return fmt.Errorf("staged DVD remux has unexpected evidence")
			}
			return nil
		}
		if record.Published == nil || record.Published.RootID != record.DVDStageRequest.RootID ||
			!dvdPublishedPathMatches(record.DVDStageRequest, record.Artifact.ID, record.Published.PathComponents) {
			return fmt.Errorf("published DVD destination is invalid")
		}
		if record.State == RemuxPublished {
			if record.Import != nil || record.Confirmation != nil {
				return fmt.Errorf("published DVD remux has unexpected import evidence")
			}
			return nil
		}
		if record.Import == nil {
			return fmt.Errorf("DVD import lacks request")
		}
		if err := validateStoredJoinImport(*record.Import, record.PreparedAt, record.UpdatedAt); err != nil {
			return err
		}
		if record.State == RemuxImportPrepared && record.Import.CommandID != nil {
			return fmt.Errorf("prepared DVD import has a command ID")
		}
		if (record.State == RemuxImportRequested || record.State == RemuxImportFailed) &&
			record.Import.CommandID == nil {
			return fmt.Errorf("requested DVD import lacks a command ID")
		}
		if record.State == RemuxImported {
			if record.Confirmation == nil || validateRadarrImportConfirmation(*record.Confirmation) != nil {
				return fmt.Errorf("imported DVD lacks confirmation")
			}
		} else if record.Confirmation != nil {
			return fmt.Errorf("unconfirmed DVD has import confirmation")
		}
	default:
		return fmt.Errorf("unknown DVD execution state %q", record.State)
	}
	return nil
}

func validRemuxArtifact(artifact *RemuxArtifact) bool {
	return artifact != nil && artifact.ID != "" && artifact.Fingerprint != "" && artifact.SizeBytes > 0
}

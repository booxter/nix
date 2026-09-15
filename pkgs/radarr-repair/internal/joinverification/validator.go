package joinverification

import (
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/workerclient"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

type RejectionReason string

const (
	InvalidStageRequest        RejectionReason = "invalid_stage_request"
	StageRequestNotAuthorized  RejectionReason = "stage_request_not_authorized"
	InvalidStageResponse       RejectionReason = "invalid_stage_response"
	StageResponseNotCorrelated RejectionReason = "stage_response_not_correlated"
	StageFailed                RejectionReason = "stage_failed"
	ArtifactSizeMismatch       RejectionReason = "artifact_size_mismatch"
	DurationUnavailable        RejectionReason = "duration_unavailable"
	DurationOutsideTolerance   RejectionReason = "duration_outside_tolerance"
	OutputContainerMismatch    RejectionReason = "output_container_mismatch"
	StreamLayoutMismatch       RejectionReason = "stream_layout_mismatch"
)

type Rejection struct {
	Reason RejectionReason
}

type ArtifactReference struct {
	ExecutionID         string
	CaseID              string
	CapabilityID        string
	ArtifactID          string
	ArtifactFingerprint string
}

type VerifiedArtifact struct {
	ArtifactReference
	SizeBytes int64
	Evidence  controller.ProbeEvidence
}

type Validation struct {
	Publish    *VerifiedArtifact
	Discard    *ArtifactReference
	Rejections []Rejection
}

func (validation Validation) Accepted() bool {
	return validation.Publish != nil && validation.Discard == nil &&
		len(validation.Rejections) == 0
}

func ValidateStagedJoin(
	authorized decisionpolicy.AuthorizedJoin,
	request workercontracts.StageJoinRequestV1,
	response workercontracts.StageJoinResponseV1,
) Validation {
	validation := Validation{Rejections: make([]Rejection, 0)}
	if _, err := workercontracts.EncodeStageJoinRequest(request); err != nil {
		return reject(validation, InvalidStageRequest)
	}
	if _, err := workercontracts.EncodeStageJoinResponse(response); err != nil {
		return reject(validation, InvalidStageResponse)
	}

	if !requestMatchesAuthorization(request, authorized) {
		validation = reject(validation, StageRequestNotAuthorized)
	}
	if response.RequestID() != request.RequestID {
		validation = reject(validation, StageResponseNotCorrelated)
	}
	if response.Kind == workercontracts.ProbeResponseFailed {
		return reject(validation, StageFailed)
	}
	if response.Success == nil {
		return reject(validation, InvalidStageResponse)
	}

	success := response.Success
	reference := ArtifactReference{
		ExecutionID:         request.ExecutionID,
		CaseID:              request.CaseID,
		CapabilityID:        request.CapabilityID,
		ArtifactID:          success.ArtifactID,
		ArtifactFingerprint: success.ArtifactFingerprint,
	}
	validation.Discard = &reference
	evidence := workerclient.EvidenceFromWorker(success.Evidence)
	if evidence.Format.SizeBytes == nil || *evidence.Format.SizeBytes <= 0 ||
		*evidence.Format.SizeBytes != success.SizeBytes {
		validation = reject(validation, ArtifactSizeMismatch)
	}

	duration := controller.AssessProbeDuration(evidence)
	if duration.Conflict || duration.EffectiveMS == nil {
		validation = reject(validation, DurationUnavailable)
	} else if !withinTolerance(
		*duration.EffectiveMS,
		authorized.ExpectedDurationMS,
		authorized.DurationToleranceMS,
	) {
		validation = reject(validation, DurationOutsideTolerance)
	}
	if !matchesContainer(authorized.OutputContainer, evidence.Format.Names) {
		validation = reject(validation, OutputContainerMismatch)
	}
	if !authorized.ExpectedStreamLayout.Matches(evidence.Streams) {
		validation = reject(validation, StreamLayoutMismatch)
	}

	if len(validation.Rejections) != 0 {
		return validation
	}
	validation.Discard = nil
	validation.Publish = &VerifiedArtifact{
		ArtifactReference: reference,
		SizeBytes:         success.SizeBytes,
		Evidence:          evidence,
	}
	return validation
}

func requestMatchesAuthorization(
	request workercontracts.StageJoinRequestV1,
	authorized decisionpolicy.AuthorizedJoin,
) bool {
	if request.CaseID != authorized.CaseID || request.CapabilityID != authorized.CapabilityID ||
		request.ExpectedSourceBytes != authorized.SourceBytes ||
		request.ExpectedDurationMS != authorized.ExpectedDurationMS ||
		request.DurationToleranceMS != authorized.DurationToleranceMS ||
		request.ExpectedStreamCount != int64(len(authorized.ExpectedStreamLayout.Streams)) ||
		string(request.OutputContainer) != string(authorized.OutputContainer) ||
		len(request.Parts) != len(authorized.OrderedParts) {
		return false
	}
	for position, part := range request.Parts {
		expected := authorized.OrderedParts[position]
		if part.FileID != string(expected.FileID) ||
			part.ExpectedFingerprint != expected.Fingerprint.Fingerprint() {
			return false
		}
	}
	return true
}

func withinTolerance(actual int64, expected int64, tolerance int64) bool {
	if actual < expected {
		return expected-actual <= tolerance
	}
	return actual-expected <= tolerance
}

func matchesContainer(expected controller.OutputContainer, names []string) bool {
	want := ""
	switch expected {
	case controller.OutputContainerAVI:
		want = "avi"
	case controller.OutputContainerMKV:
		want = "matroska"
	case controller.OutputContainerMP4:
		want = "mp4"
	default:
		return false
	}
	for _, name := range names {
		if name == want {
			return true
		}
	}
	return false
}

func reject(validation Validation, reason RejectionReason) Validation {
	validation.Rejections = append(validation.Rejections, Rejection{Reason: reason})
	return validation
}

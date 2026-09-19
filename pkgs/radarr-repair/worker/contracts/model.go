package workercontracts

type BlurayIdentifyRequestV1 = RadarrRepairWorkerBluRayIdentificationRequest
type BlurayIdentifySuccessV1 = BlurayIdentifySuccessResponseV1Class
type BlurayIdentifyFailureV1 = BlurayIdentifyFailureResponseV1Class

type BlurayIdentifyResponseV1 struct {
	Kind    ProbeResponseKind
	Success *BlurayIdentifySuccessV1
	Failure *BlurayIdentifyFailureV1
}

func (response BlurayIdentifyResponseV1) RequestID() string {
	return operationResponseRequestID(
		response.Kind,
		response.Success,
		response.Failure,
		func(success *BlurayIdentifySuccessV1) string { return success.RequestID },
		func(failure *BlurayIdentifyFailureV1) string { return failure.RequestID },
	)
}

type ProbeRequestV1 = RadarrRepairWorkerProbeRequestVersion1
type ProbeSuccessResponseV1 = ProbeSuccessResponseV1Class
type ProbeFailureResponseV1 = ProbeFailureResponseV1Class
type Operation = ProbeFailureResponseV1Operation
type Reason = ProbeFailureResponseV1Reason
type ProbeFailureResponseV1Status = BlurayIdentifyFailureResponseV1Status
type ProbeSuccessResponseV1Status = BlurayIdentifySuccessResponseV1Status

const Failed ProbeFailureResponseV1Status = "failed"

const (
	FileUnavailable     Reason = "file_unavailable"
	FingerprintMismatch Reason = "fingerprint_mismatch"
	InternalError       Reason = "internal_error"
	InvalidOutput       Reason = "invalid_output"
	InvalidPath         Reason = "invalid_path"
	NotRegularFile      Reason = "not_regular_file"
	ProbeError          Reason = "probe_error"
	Timeout             Reason = "timeout"
	UnknownRoot         Reason = "unknown_root"
)

type ProbeResponseKind string

const (
	ProbeResponseSucceeded ProbeResponseKind = "ok"
	ProbeResponseFailed    ProbeResponseKind = "failed"
)

type ProbeResponseV1 struct {
	Kind    ProbeResponseKind
	Success *ProbeSuccessResponseV1
	Failure *ProbeFailureResponseV1
}

func (response ProbeResponseV1) RequestID() string {
	switch response.Kind {
	case ProbeResponseSucceeded:
		if response.Success != nil {
			return response.Success.RequestID
		}
	case ProbeResponseFailed:
		if response.Failure != nil {
			return response.Failure.RequestID
		}
	}
	return ""
}

type StageJoinPartV1 = JoinRequestSchema

type StageJoinResponseV1 struct {
	Kind    ProbeResponseKind
	Success *StageJoinSuccessResponseV1
	Failure *StageJoinFailureResponseV1
}

func (response StageJoinResponseV1) RequestID() string {
	return operationResponseRequestID(
		response.Kind,
		response.Success,
		response.Failure,
		func(success *StageJoinSuccessResponseV1) string { return success.RequestID },
		func(failure *StageJoinFailureResponseV1) string { return failure.RequestID },
	)
}

type PublishResponseV1 struct {
	Kind    ProbeResponseKind
	Success *PublishSuccessResponseV1
	Failure *PublishFailureResponseV1
}

func (response PublishResponseV1) RequestID() string {
	return operationResponseRequestID(
		response.Kind,
		response.Success,
		response.Failure,
		func(success *PublishSuccessResponseV1) string { return success.RequestID },
		func(failure *PublishFailureResponseV1) string { return failure.RequestID },
	)
}

type DiscardResponseV1 struct {
	Kind    ProbeResponseKind
	Success *DiscardSuccessResponseV1
	Failure *DiscardFailureResponseV1
}

func (response DiscardResponseV1) RequestID() string {
	return operationResponseRequestID(
		response.Kind,
		response.Success,
		response.Failure,
		func(success *DiscardSuccessResponseV1) string { return success.RequestID },
		func(failure *DiscardFailureResponseV1) string { return failure.RequestID },
	)
}

type InspectJoinResponseV1 struct {
	Kind    ProbeResponseKind
	Success *InspectJoinSuccessResponseV1
	Failure *InspectJoinFailureResponseV1
}

func (response InspectJoinResponseV1) RequestID() string {
	return operationResponseRequestID(
		response.Kind,
		response.Success,
		response.Failure,
		func(success *InspectJoinSuccessResponseV1) string { return success.RequestID },
		func(failure *InspectJoinFailureResponseV1) string { return failure.RequestID },
	)
}

func operationResponseRequestID[S any, F any](
	kind ProbeResponseKind,
	success *S,
	failure *F,
	successRequestID func(*S) string,
	failureRequestID func(*F) string,
) string {
	switch kind {
	case ProbeResponseSucceeded:
		if success != nil {
			return successRequestID(success)
		}
	case ProbeResponseFailed:
		if failure != nil {
			return failureRequestID(failure)
		}
	}
	return ""
}

type StageJoinFailureReason = StageJoinFailureResponseV1Reason

const (
	StageJoinUnknownRoot         StageJoinFailureReason = "unknown_root"
	StageJoinInvalidPath         StageJoinFailureReason = "invalid_path"
	StageJoinFileUnavailable     StageJoinFailureReason = "file_unavailable"
	StageJoinNotRegularFile      StageJoinFailureReason = "not_regular_file"
	StageJoinFingerprintMismatch StageJoinFailureReason = "fingerprint_mismatch"
	StageJoinSourceSizeMismatch  StageJoinFailureReason = "source_size_mismatch"
	StageJoinInsufficientSpace   StageJoinFailureReason = "insufficient_space"
	StageJoinExecutionConflict   StageJoinFailureReason = "execution_conflict"
	StageJoinJoinError           StageJoinFailureReason = "join_error"
	StageJoinTimeout             StageJoinFailureReason = "timeout"
	StageJoinProbeError          StageJoinFailureReason = "probe_error"
	StageJoinInvalidOutput       StageJoinFailureReason = "invalid_output"
	StageJoinInternalError       StageJoinFailureReason = "internal_error"
	OutputContainerAVI           OutputContainer        = "avi"
	OutputContainerMKV           OutputContainer        = "mkv"
	OutputContainerMP4           OutputContainer        = "mp4"
)

type PublishFailureReason = PublishFailureResponseV1Reason

const (
	PublishArtifactNotFound            PublishFailureReason = "artifact_not_found"
	PublishArtifactFingerprintMismatch PublishFailureReason = "artifact_fingerprint_mismatch"
	PublishArtifactNotStaged           PublishFailureReason = "artifact_not_staged"
	PublishDestinationExists           PublishFailureReason = "destination_exists"
	PublishErrorReason                 PublishFailureReason = "publish_error"
	PublishInternalError               PublishFailureReason = "internal_error"
)

type DiscardFailureReason = DiscardFailureResponseV1Reason

const (
	DiscardArtifactNotFound            DiscardFailureReason = "artifact_not_found"
	DiscardArtifactFingerprintMismatch DiscardFailureReason = "artifact_fingerprint_mismatch"
	DiscardArtifactPublished           DiscardFailureReason = "artifact_published"
	DiscardErrorReason                 DiscardFailureReason = "discard_error"
	DiscardInternalError               DiscardFailureReason = "internal_error"
)

type InspectJoinState = State
type InspectJoinFailureReason = InspectJoinFailureResponseV1Reason

const (
	InspectJoinAbsent    InspectJoinState         = "absent"
	InspectJoinPrepared  InspectJoinState         = "prepared"
	InspectJoinStaged    InspectJoinState         = "staged"
	InspectJoinPublished InspectJoinState         = "published"
	InspectJoinDiscarded InspectJoinState         = "discarded"
	InspectJoinFailed    InspectJoinState         = "failed"
	InspectJoinInternal  InspectJoinFailureReason = "internal_error"
)

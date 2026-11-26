package workercontracts

type DVDIdentifyRequestV1 = RadarrRepairWorkerDVDIdentificationRequest
type DVDIdentifySuccessV1 = DVDIdentifySuccessResponseV1Class
type DVDIdentifyFailureV1 = DVDIdentifyFailureResponseV1Class
type DVDTitleV1 = TitleElement
type DVDTrackV1 = TitleTrack
type Track = BlurayIdentifySuccessResponseV1Track

type DVDIdentifyResponseV1 struct {
	Kind    ProbeResponseKind
	Success *DVDIdentifySuccessV1
	Failure *DVDIdentifyFailureV1
}

func (response DVDIdentifyResponseV1) RequestID() string {
	return operationResponseRequestID(response.Kind, response.Success, response.Failure,
		func(success *DVDIdentifySuccessV1) string { return success.RequestID },
		func(failure *DVDIdentifyFailureV1) string { return failure.RequestID })
}

type BlurayIdentifyRequestV1 = RadarrRepairWorkerBluRayIdentificationRequest
type BlurayIdentifySuccessV1 = BlurayIdentifySuccessResponseV1Class
type BlurayIdentifyFailureV1 = BlurayIdentifyFailureResponseV1Class

type BlurayIdentifyResponseV1 struct {
	Kind    ProbeResponseKind
	Success *BlurayIdentifySuccessV1
	Failure *BlurayIdentifyFailureV1
}

func (response BlurayIdentifyResponseV1) RequestID() string {
	return operationResponseRequestID(response.Kind, response.Success, response.Failure,
		func(success *BlurayIdentifySuccessV1) string { return success.RequestID },
		func(failure *BlurayIdentifyFailureV1) string { return failure.RequestID })
}

type ProbeRequestV1 = RadarrRepairWorkerProbeRequestVersion1
type ProbeSuccessResponseV1 = ProbeSuccessResponseV1Class
type ProbeFailureResponseV1 = ProbeFailureResponseV1Class
type Operation = ProbeFailureResponseV1Operation
type Reason = ProbeFailureResponseV1Reason
type ProbeFailureResponseV1Status = BlurayIdentifyFailureResponseV1Status
type ProbeSuccessResponseV1Status = BlurayIdentifySuccessResponseV1Status

const (
	FileUnavailable     Reason = "file_unavailable"
	FingerprintMismatch Reason = "fingerprint_mismatch"
	InternalError       Reason = "internal_error"
	InvalidOutput       Reason = "invalid_output"
	InvalidPath         Reason = "invalid_path"
	NotRegularFile      Reason = "not_regular_file"
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
	return operationResponseRequestID(response.Kind, response.Success, response.Failure,
		func(success *ProbeSuccessResponseV1) string { return success.RequestID },
		func(failure *ProbeFailureResponseV1) string { return failure.RequestID })
}

func operationResponseRequestID[S any, F any](
	kind ProbeResponseKind, success *S, failure *F,
	successRequestID func(*S) string, failureRequestID func(*F) string,
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

// These types describe internal staging results, not worker wire operations.
type StageJoinFailureReason string
type OutputContainer string

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

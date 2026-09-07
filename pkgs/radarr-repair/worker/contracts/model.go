package workercontracts

type ProbeRequestV1 = RadarrRepairWorkerProbeRequestVersion1
type ProbeSuccessResponseV1 = ProbeSuccessResponseV1Class
type ProbeFailureResponseV1 = ProbeFailureResponseV1Class

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

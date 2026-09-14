package workercontracts

import (
	"encoding/json"
	"fmt"
)

func EncodeProbeRequest(request ProbeRequestV1) ([]byte, error) {
	data, err := json.Marshal(request)
	if err != nil {
		return nil, fmt.Errorf("encode probe request: %w", err)
	}
	if err := validateMessage(
		data,
		MaxProbeRequestBytes,
		"probe request",
		probeRequestSchema,
	); err != nil {
		return nil, err
	}
	return data, nil
}

func EncodeProbeResponse(response ProbeResponseV1) ([]byte, error) {
	var message any
	switch response.Kind {
	case ProbeResponseSucceeded:
		if response.Success == nil || response.Failure != nil {
			return nil, fmt.Errorf("successful probe response must contain only success")
		}
		message = response.Success
	case ProbeResponseFailed:
		if response.Failure == nil || response.Success != nil {
			return nil, fmt.Errorf("failed probe response must contain only failure")
		}
		message = response.Failure
	default:
		return nil, fmt.Errorf("unsupported probe response kind %q", response.Kind)
	}

	data, err := json.Marshal(message)
	if err != nil {
		return nil, fmt.Errorf("encode probe response: %w", err)
	}
	if err := validateMessage(
		data,
		MaxProbeResponseBytes,
		"probe response",
		probeResponseSchema,
	); err != nil {
		return nil, err
	}
	return data, nil
}

func EncodeStageJoinRequest(request StageJoinRequestV1) ([]byte, error) {
	return encodeJoinRequest(request, "stage join request")
}

func EncodePublishRequest(request PublishRequestV1) ([]byte, error) {
	return encodeJoinRequest(request, "publish request")
}

func EncodeDiscardRequest(request DiscardRequestV1) ([]byte, error) {
	return encodeJoinRequest(request, "discard request")
}

func EncodeInspectJoinRequest(request InspectJoinRequestV1) ([]byte, error) {
	return encodeJoinRequest(request, "inspect join request")
}

func EncodeStageJoinResponse(response StageJoinResponseV1) ([]byte, error) {
	return encodeJoinResponse(
		response.Kind,
		response.Success,
		response.Failure,
		"stage join response",
	)
}

func EncodePublishResponse(response PublishResponseV1) ([]byte, error) {
	return encodeJoinResponse(
		response.Kind,
		response.Success,
		response.Failure,
		"publish response",
	)
}

func EncodeDiscardResponse(response DiscardResponseV1) ([]byte, error) {
	return encodeJoinResponse(
		response.Kind,
		response.Success,
		response.Failure,
		"discard response",
	)
}

func EncodeInspectJoinResponse(response InspectJoinResponseV1) ([]byte, error) {
	return encodeJoinResponse(
		response.Kind,
		response.Success,
		response.Failure,
		"inspect join response",
	)
}

func encodeJoinRequest(request any, name string) ([]byte, error) {
	data, err := json.Marshal(request)
	if err != nil {
		return nil, fmt.Errorf("encode %s: %w", name, err)
	}
	if err := validateMessage(
		data,
		MaxJoinRequestBytes,
		name,
		joinRequestSchema,
	); err != nil {
		return nil, err
	}
	return data, nil
}

func encodeJoinResponse[S any, F any](
	kind ProbeResponseKind,
	success *S,
	failure *F,
	name string,
) ([]byte, error) {
	var message any
	switch kind {
	case ProbeResponseSucceeded:
		if success == nil || failure != nil {
			return nil, fmt.Errorf("successful %s must contain only success", name)
		}
		message = success
	case ProbeResponseFailed:
		if failure == nil || success != nil {
			return nil, fmt.Errorf("failed %s must contain only failure", name)
		}
		message = failure
	default:
		return nil, fmt.Errorf("unsupported %s kind %q", name, kind)
	}

	data, err := json.Marshal(message)
	if err != nil {
		return nil, fmt.Errorf("encode %s: %w", name, err)
	}
	if err := validateMessage(
		data,
		MaxJoinResponseBytes,
		name,
		joinResponseSchema,
	); err != nil {
		return nil, err
	}
	return data, nil
}

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

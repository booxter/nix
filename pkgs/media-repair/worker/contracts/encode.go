package workercontracts

import (
	"encoding/json"
	"fmt"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

func EncodeDVDIdentifyRequest(request DVDIdentifyRequestV1) ([]byte, error) {
	data, err := json.Marshal(request)
	if err != nil {
		return nil, fmt.Errorf("encode DVD identification request: %w", err)
	}
	if err := validateMessage(
		data, MaxDVDIdentifyRequestBytes, "DVD identification request",
		dvdIdentifyRequestSchema,
	); err != nil {
		return nil, err
	}
	return data, nil
}

func EncodeDVDIdentifyResponse(response DVDIdentifyResponseV1) ([]byte, error) {
	return encodeOperationResponse(
		response.Kind, response.Success, response.Failure,
		"DVD identification response", MaxDVDIdentifyResponseBytes,
		dvdIdentifyResponseSchema,
	)
}

func EncodeBlurayIdentifyRequest(request BlurayIdentifyRequestV1) ([]byte, error) {
	data, err := json.Marshal(request)
	if err != nil {
		return nil, fmt.Errorf("encode Blu-ray identification request: %w", err)
	}
	if err := validateMessage(
		data,
		MaxBlurayIdentifyRequestBytes,
		"Blu-ray identification request",
		blurayIdentifyRequestSchema,
	); err != nil {
		return nil, err
	}
	return data, nil
}

func EncodeBlurayIdentifyResponse(response BlurayIdentifyResponseV1) ([]byte, error) {
	return encodeOperationResponse(
		response.Kind,
		response.Success,
		response.Failure,
		"Blu-ray identification response",
		MaxBlurayIdentifyResponseBytes,
		blurayIdentifyResponseSchema,
	)
}

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

func encodeOperationResponse[S any, F any](
	kind ProbeResponseKind,
	success *S,
	failure *F,
	name string,
	limit int,
	loadSchema func() (*jsonschema.Schema, error),
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
	if err := validateMessage(data, limit, name, loadSchema); err != nil {
		return nil, err
	}
	return data, nil
}

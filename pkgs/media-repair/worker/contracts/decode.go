package workercontracts

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

func DecodeProbeRequest(data []byte) (ProbeRequestV1, error) {
	var request ProbeRequestV1
	if err := validateAndDecode(
		data,
		MaxProbeRequestBytes,
		"probe request",
		probeRequestSchema,
		&request,
	); err != nil {
		return ProbeRequestV1{}, err
	}
	return request, nil
}

func DecodeDVDIdentifyRequest(data []byte) (DVDIdentifyRequestV1, error) {
	var request DVDIdentifyRequestV1
	if err := validateAndDecode(
		data, MaxDVDIdentifyRequestBytes, "DVD identification request",
		dvdIdentifyRequestSchema, &request,
	); err != nil {
		return DVDIdentifyRequestV1{}, err
	}
	return request, nil
}

func DecodeDVDIdentifyResponse(data []byte) (DVDIdentifyResponseV1, error) {
	kind, success, failure, err := decodeOperationResponse[
		DVDIdentifySuccessV1, DVDIdentifyFailureV1,
	](
		data, "DVD identification response", "identify_dvd_v1",
		MaxDVDIdentifyResponseBytes, dvdIdentifyResponseSchema,
	)
	if err != nil {
		return DVDIdentifyResponseV1{}, err
	}
	return DVDIdentifyResponseV1{Kind: kind, Success: success, Failure: failure}, nil
}

func DecodeBlurayIdentifyRequest(data []byte) (BlurayIdentifyRequestV1, error) {
	var request BlurayIdentifyRequestV1
	if err := validateAndDecode(
		data,
		MaxBlurayIdentifyRequestBytes,
		"Blu-ray identification request",
		blurayIdentifyRequestSchema,
		&request,
	); err != nil {
		return BlurayIdentifyRequestV1{}, err
	}
	return request, nil
}

func DecodeBlurayIdentifyResponse(data []byte) (BlurayIdentifyResponseV1, error) {
	kind, success, failure, err := decodeOperationResponse[
		BlurayIdentifySuccessV1,
		BlurayIdentifyFailureV1,
	](
		data,
		"Blu-ray identification response",
		"identify_bluray_v1",
		MaxBlurayIdentifyResponseBytes,
		blurayIdentifyResponseSchema,
	)
	if err != nil {
		return BlurayIdentifyResponseV1{}, err
	}
	return BlurayIdentifyResponseV1{Kind: kind, Success: success, Failure: failure}, nil
}

func DecodeProbeResponse(data []byte) (ProbeResponseV1, error) {
	if err := validateMessage(
		data,
		MaxProbeResponseBytes,
		"probe response",
		probeResponseSchema,
	); err != nil {
		return ProbeResponseV1{}, err
	}

	var envelope struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return ProbeResponseV1{}, fmt.Errorf("decode probe response status: %w", err)
	}

	switch ProbeResponseKind(envelope.Status) {
	case ProbeResponseSucceeded:
		var response ProbeSuccessResponseV1
		if err := decodeStrict(data, "probe response", &response); err != nil {
			return ProbeResponseV1{}, err
		}
		return ProbeResponseV1{Kind: ProbeResponseSucceeded, Success: &response}, nil
	case ProbeResponseFailed:
		var response ProbeFailureResponseV1
		if err := decodeStrict(data, "probe response", &response); err != nil {
			return ProbeResponseV1{}, err
		}
		return ProbeResponseV1{Kind: ProbeResponseFailed, Failure: &response}, nil
	default:
		return ProbeResponseV1{}, fmt.Errorf("unsupported probe response status %q", envelope.Status)
	}
}

func decodeOperationResponse[S any, F any](
	data []byte,
	name string,
	operation string,
	limit int,
	loadSchema func() (*jsonschema.Schema, error),
) (ProbeResponseKind, *S, *F, error) {
	if err := validateMessage(data, limit, name, loadSchema); err != nil {
		return "", nil, nil, err
	}
	var envelope struct {
		Operation string `json:"operation"`
		Status    string `json:"status"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return "", nil, nil, fmt.Errorf("decode %s envelope: %w", name, err)
	}
	if envelope.Operation != operation {
		return "", nil, nil, fmt.Errorf(
			"decode %s: received operation %q",
			name,
			envelope.Operation,
		)
	}

	switch ProbeResponseKind(envelope.Status) {
	case ProbeResponseSucceeded:
		var response S
		if err := decodeStrict(data, name, &response); err != nil {
			return "", nil, nil, err
		}
		return ProbeResponseSucceeded, &response, nil, nil
	case ProbeResponseFailed:
		var response F
		if err := decodeStrict(data, name, &response); err != nil {
			return "", nil, nil, err
		}
		return ProbeResponseFailed, nil, &response, nil
	default:
		return "", nil, nil, fmt.Errorf(
			"decode %s: unsupported status %q",
			name,
			envelope.Status,
		)
	}
}

func validateAndDecode(
	data []byte,
	limit int,
	name string,
	loadSchema func() (*jsonschema.Schema, error),
	destination any,
) error {
	if err := validateMessage(data, limit, name, loadSchema); err != nil {
		return err
	}
	return decodeStrict(data, name, destination)
}

func validateMessage(
	data []byte,
	limit int,
	name string,
	loadSchema func() (*jsonschema.Schema, error),
) error {
	if len(data) > limit {
		return fmt.Errorf("%s is %d bytes, limit is %d", name, len(data), limit)
	}
	schema, err := loadSchema()
	if err != nil {
		return err
	}
	document, err := jsonschema.UnmarshalJSON(bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("parse %s JSON: %w", name, err)
	}
	if err := schema.Validate(document); err != nil {
		return fmt.Errorf("validate %s schema: %w", name, err)
	}
	return nil
}

func decodeStrict(data []byte, name string, destination any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return fmt.Errorf("decode %s: %w", name, err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("decode %s: multiple JSON values", name)
		}
		return fmt.Errorf("decode %s trailing data: %w", name, err)
	}
	return nil
}

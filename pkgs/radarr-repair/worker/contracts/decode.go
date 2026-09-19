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

func DecodeStageJoinRequest(data []byte) (StageJoinRequestV1, error) {
	return decodeJoinRequest[StageJoinRequestV1](data, "stage join request", "stage_join_v1")
}

func DecodePublishRequest(data []byte) (PublishRequestV1, error) {
	return decodeJoinRequest[PublishRequestV1](data, "publish request", "publish_v1")
}

func DecodeDiscardRequest(data []byte) (DiscardRequestV1, error) {
	return decodeJoinRequest[DiscardRequestV1](data, "discard request", "discard_v1")
}

func DecodeInspectJoinRequest(data []byte) (InspectJoinRequestV1, error) {
	return decodeJoinRequest[InspectJoinRequestV1](data, "inspect join request", "inspect_join_v1")
}

func DecodeStageJoinResponse(data []byte) (StageJoinResponseV1, error) {
	kind, success, failure, err := decodeJoinResponse[
		StageJoinSuccessResponseV1,
		StageJoinFailureResponseV1,
	](data, "stage join response", "stage_join_v1")
	if err != nil {
		return StageJoinResponseV1{}, err
	}
	return StageJoinResponseV1{Kind: kind, Success: success, Failure: failure}, nil
}

func DecodePublishResponse(data []byte) (PublishResponseV1, error) {
	kind, success, failure, err := decodeJoinResponse[
		PublishSuccessResponseV1,
		PublishFailureResponseV1,
	](data, "publish response", "publish_v1")
	if err != nil {
		return PublishResponseV1{}, err
	}
	return PublishResponseV1{Kind: kind, Success: success, Failure: failure}, nil
}

func DecodeDiscardResponse(data []byte) (DiscardResponseV1, error) {
	kind, success, failure, err := decodeJoinResponse[
		DiscardSuccessResponseV1,
		DiscardFailureResponseV1,
	](data, "discard response", "discard_v1")
	if err != nil {
		return DiscardResponseV1{}, err
	}
	return DiscardResponseV1{Kind: kind, Success: success, Failure: failure}, nil
}

func DecodeInspectJoinResponse(data []byte) (InspectJoinResponseV1, error) {
	kind, success, failure, err := decodeJoinResponse[
		InspectJoinSuccessResponseV1,
		InspectJoinFailureResponseV1,
	](data, "inspect join response", "inspect_join_v1")
	if err != nil {
		return InspectJoinResponseV1{}, err
	}
	return InspectJoinResponseV1{Kind: kind, Success: success, Failure: failure}, nil
}

func decodeJoinRequest[T any](data []byte, name string, operation string) (T, error) {
	var request T
	if err := validateMessage(data, MaxJoinRequestBytes, name, joinRequestSchema); err != nil {
		return request, err
	}
	var envelope struct {
		Operation string `json:"operation"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return request, fmt.Errorf("decode %s operation: %w", name, err)
	}
	if envelope.Operation != operation {
		return request, fmt.Errorf(
			"decode %s: received operation %q",
			name,
			envelope.Operation,
		)
	}
	if err := decodeStrict(data, name, &request); err != nil {
		return request, err
	}
	return request, nil
}

func decodeJoinResponse[S any, F any](
	data []byte,
	name string,
	operation string,
) (ProbeResponseKind, *S, *F, error) {
	return decodeOperationResponse[S, F](
		data, name, operation, MaxJoinResponseBytes, joinResponseSchema,
	)
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

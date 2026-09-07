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

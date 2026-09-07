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
	if len(data) > MaxProbeRequestBytes {
		return ProbeRequestV1{}, fmt.Errorf(
			"probe request is %d bytes, limit is %d",
			len(data),
			MaxProbeRequestBytes,
		)
	}

	schema, err := probeRequestSchema()
	if err != nil {
		return ProbeRequestV1{}, err
	}
	document, err := jsonschema.UnmarshalJSON(bytes.NewReader(data))
	if err != nil {
		return ProbeRequestV1{}, fmt.Errorf("parse probe request JSON: %w", err)
	}
	if err := schema.Validate(document); err != nil {
		return ProbeRequestV1{}, fmt.Errorf("validate probe request schema: %w", err)
	}

	var request ProbeRequestV1
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return ProbeRequestV1{}, fmt.Errorf("decode probe request: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return ProbeRequestV1{}, fmt.Errorf("decode probe request: multiple JSON values")
		}
		return ProbeRequestV1{}, fmt.Errorf("decode probe request trailing data: %w", err)
	}
	return request, nil
}

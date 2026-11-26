package planning

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"slices"
)

// Inputs contains only evidence whose changes warrant another model decision.
// Adapters normalize their typed inputs; the framework owns their identity.
type Inputs struct {
	encoded []byte
	fields  map[string]json.RawMessage
}

func NewInputs[T any](value T) (Inputs, error) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return Inputs{}, fmt.Errorf("encode planning inputs: %w", err)
	}

	var fields map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &fields); err != nil {
		return Inputs{}, fmt.Errorf("planning inputs must be an object: %w", err)
	}
	if len(fields) == 0 {
		return Inputs{}, fmt.Errorf("planning inputs must not be empty")
	}

	return Inputs{encoded: encoded, fields: fields}, nil
}

func (inputs Inputs) Fingerprint() string {
	if len(inputs.encoded) == 0 {
		return ""
	}
	digest := sha256.Sum256(inputs.encoded)
	return fmt.Sprintf("sha256:%x", digest)
}

func (inputs Inputs) Changes(previous Inputs) []string {
	var changes []string
	for name, value := range inputs.fields {
		if !bytes.Equal(value, previous.fields[name]) {
			changes = append(changes, name)
		}
	}
	for name := range previous.fields {
		if _, present := inputs.fields[name]; !present {
			changes = append(changes, name)
		}
	}
	slices.Sort(changes)
	return changes
}

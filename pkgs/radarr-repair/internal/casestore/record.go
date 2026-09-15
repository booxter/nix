package casestore

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
)

const (
	RecordVersionV1 = "radarr-repair-state/v1"
	RecordVersionV2 = "radarr-repair-state/v2"
)

// CaseRecord keeps the planner-visible request together with the local facts
// that give its opaque identifiers meaning. It is private controller state,
// not part of the planner protocol.
type CaseRecord struct {
	Version  string                    `json:"version"`
	CaseID   string                    `json:"case_id"`
	Request  json.RawMessage           `json:"request"`
	Snapshot casebuilder.LocalSnapshot `json:"snapshot"`
}

func NewRecord(assembly casebuilder.Assembly) (CaseRecord, error) {
	encodedRequest, err := contracts.EncodeCase(assembly.Request)
	if err != nil {
		return CaseRecord{}, fmt.Errorf("encode assembly request: %w", err)
	}
	if !bytes.Equal(encodedRequest, assembly.EncodedRequest) {
		return CaseRecord{}, fmt.Errorf("assembly request bytes do not match its typed request")
	}
	record := CaseRecord{
		Version:  RecordVersionV2,
		CaseID:   assembly.Request.CaseID,
		Request:  cloneBytes(assembly.EncodedRequest),
		Snapshot: assembly.LocalSnapshot,
	}
	if err := validateRecord(record); err != nil {
		return CaseRecord{}, err
	}
	return record, nil
}

func EncodeRecord(record CaseRecord) ([]byte, error) {
	if err := validateRecord(record); err != nil {
		return nil, err
	}
	data, err := json.Marshal(record)
	if err != nil {
		return nil, fmt.Errorf("encode case record: %w", err)
	}
	return data, nil
}

func DecodeRecord(data []byte) (CaseRecord, error) {
	var record CaseRecord
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return CaseRecord{}, fmt.Errorf("decode case record: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return CaseRecord{}, fmt.Errorf("decode case record: multiple JSON values")
		}
		return CaseRecord{}, fmt.Errorf("decode case record trailing JSON: %w", err)
	}
	if err := validateRecord(record); err != nil {
		return CaseRecord{}, err
	}
	record.Request = cloneBytes(record.Request)
	return record, nil
}

func validateRecord(record CaseRecord) error {
	if record.Version != RecordVersionV1 && record.Version != RecordVersionV2 {
		return fmt.Errorf("unsupported case record version %q", record.Version)
	}
	request, err := contracts.DecodeCase(record.Request)
	if err != nil {
		return fmt.Errorf("decode stored repair case: %w", err)
	}
	canonicalRequest, err := contracts.EncodeCase(request)
	if err != nil {
		return fmt.Errorf("validate stored repair case: %w", err)
	}
	if !bytes.Equal(record.Request, canonicalRequest) {
		return fmt.Errorf("stored repair case is not in canonical encoded form")
	}
	if record.CaseID != request.CaseID {
		return fmt.Errorf("record case ID does not match its repair case")
	}
	if record.Snapshot.CaseID != record.CaseID {
		return fmt.Errorf("snapshot case ID does not match its record")
	}

	rebuilt, err := casebuilder.Assemble(record.Snapshot.Observation)
	if err != nil {
		return fmt.Errorf("reassemble stored observation: %w", err)
	}
	if !bytes.Equal(rebuilt.EncodedRequest, record.Request) {
		return fmt.Errorf("stored observation does not reproduce its repair case")
	}
	if !reflect.DeepEqual(
		rebuilt.LocalSnapshot.ManualImportBindings,
		record.Snapshot.ManualImportBindings,
	) {
		return fmt.Errorf("stored manual import bindings do not match the repair case")
	}
	return nil
}

func cloneBytes(value []byte) []byte {
	if value == nil {
		return nil
	}
	cloned := make([]byte, len(value))
	copy(cloned, value)
	return cloned
}

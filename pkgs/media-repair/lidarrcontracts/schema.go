package lidarrcontracts

import (
	"bytes"
	"embed"
	"fmt"
	"sync"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

const (
	caseSchemaV2File         = "v2/repair-case.schema.json"
	caseSchemaV2Location     = "urn:lidarr-repair:schema:repair-case:v2"
	decisionSchemaV2File     = "v2/repair-decision.schema.json"
	decisionSchemaV2Location = "urn:lidarr-repair:schema:repair-decision:v2"
	caseSchemaV3File         = "v3/repair-case.schema.json"
	caseSchemaV3Location     = "urn:lidarr-repair:schema:repair-case:v3"
	decisionSchemaV3File     = "v3/repair-decision.schema.json"
	decisionSchemaV3Location = "urn:lidarr-repair:schema:repair-decision:v3"
)

//go:embed v2/repair-case.schema.json v2/repair-decision.schema.json v3/repair-case.schema.json v3/repair-decision.schema.json
var schemaFiles embed.FS

var caseSchemaV2 = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(caseSchemaV2File, caseSchemaV2Location)
})

var decisionSchemaV2 = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(decisionSchemaV2File, decisionSchemaV2Location)
})

var caseSchemaV3 = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(caseSchemaV3File, caseSchemaV3Location)
})

var decisionSchemaV3 = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(decisionSchemaV3File, decisionSchemaV3Location)
})

func DecisionSchemaJSON() ([]byte, error) {
	data, err := schemaFiles.ReadFile(decisionSchemaV3File)
	if err != nil {
		return nil, fmt.Errorf("read embedded Lidarr decision schema: %w", err)
	}
	return data, nil
}

func loadCaseSchema(version string) (*jsonschema.Schema, error) {
	switch version {
	case LidarrRepairV2:
		return caseSchemaV2()
	case SchemaVersion:
		return caseSchemaV3()
	default:
		return nil, fmt.Errorf("unsupported Lidarr repair case schema version %q", version)
	}
}

func loadDecisionSchema(version string) (*jsonschema.Schema, error) {
	switch version {
	case LidarrRepairV2:
		return decisionSchemaV2()
	case SchemaVersion:
		return decisionSchemaV3()
	default:
		return nil, fmt.Errorf("unsupported Lidarr repair decision schema version %q", version)
	}
}

func compileSchema(fileName, location string) (*jsonschema.Schema, error) {
	data, err := schemaFiles.ReadFile(fileName)
	if err != nil {
		return nil, fmt.Errorf("read embedded schema %s: %w", fileName, err)
	}
	document, err := jsonschema.UnmarshalJSON(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("parse embedded schema %s: %w", fileName, err)
	}
	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft2020)
	compiler.AssertFormat()
	if err := compiler.AddResource(location, document); err != nil {
		return nil, fmt.Errorf("register embedded schema %s: %w", fileName, err)
	}
	schema, err := compiler.Compile(location)
	if err != nil {
		return nil, fmt.Errorf("compile embedded schema %s: %w", fileName, err)
	}
	return schema, nil
}

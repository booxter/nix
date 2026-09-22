package lidarrcontracts

import (
	"bytes"
	"embed"
	"fmt"
	"sync"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

const (
	caseSchemaFile         = "v1/repair-case.schema.json"
	caseSchemaLocation     = "urn:lidarr-repair:schema:repair-case:v1"
	decisionSchemaFile     = "v1/repair-decision.schema.json"
	decisionSchemaLocation = "urn:lidarr-repair:schema:repair-decision:v1"
)

//go:embed v1/repair-case.schema.json v1/repair-decision.schema.json
var schemaFiles embed.FS

var caseSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(caseSchemaFile, caseSchemaLocation)
})

var decisionSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(decisionSchemaFile, decisionSchemaLocation)
})

func DecisionSchemaJSON() ([]byte, error) {
	data, err := schemaFiles.ReadFile(decisionSchemaFile)
	if err != nil {
		return nil, fmt.Errorf("read embedded Lidarr decision schema: %w", err)
	}
	return data, nil
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

package workercontracts

import (
	"bytes"
	"embed"
	"fmt"
	"sync"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

// MaxProbeRequestBytes accommodates the schema's maximum 32 path components
// of 255 bytes each plus the fixed request fields and JSON encoding overhead.
const MaxProbeRequestBytes = 16 << 10

// MaxProbeResponseBytes matches the maximum metadata document accepted from
// ffprobe; responses never contain media payloads.
const MaxProbeResponseBytes = 4 << 20

const (
	probeRequestSchemaFile      = "v1/probe-request.schema.json"
	probeRequestSchemaLocation  = "urn:radarr-repair-worker:schema:probe-request:v1"
	probeResponseSchemaFile     = "v1/probe-response.schema.json"
	probeResponseSchemaLocation = "urn:radarr-repair-worker:schema:probe-response:v1"
)

//go:embed v1/probe-request.schema.json v1/probe-response.schema.json
var schemaFiles embed.FS

var probeRequestSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(probeRequestSchemaFile, probeRequestSchemaLocation)
})

var probeResponseSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(probeResponseSchemaFile, probeResponseSchemaLocation)
})

func compileSchema(fileName string, location string) (*jsonschema.Schema, error) {
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

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
const (
	MaxProbeRequestBytes       = 16 << 10
	probeRequestSchemaFile     = "v1/probe-request.schema.json"
	probeRequestSchemaLocation = "urn:radarr-repair-worker:schema:probe-request:v1"
)

//go:embed v1/probe-request.schema.json
var schemaFiles embed.FS

var probeRequestSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	data, err := schemaFiles.ReadFile(probeRequestSchemaFile)
	if err != nil {
		return nil, fmt.Errorf("read embedded schema %s: %w", probeRequestSchemaFile, err)
	}
	document, err := jsonschema.UnmarshalJSON(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("parse embedded schema %s: %w", probeRequestSchemaFile, err)
	}
	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft2020)
	compiler.AssertFormat()
	if err := compiler.AddResource(probeRequestSchemaLocation, document); err != nil {
		return nil, fmt.Errorf("register embedded schema %s: %w", probeRequestSchemaFile, err)
	}
	schema, err := compiler.Compile(probeRequestSchemaLocation)
	if err != nil {
		return nil, fmt.Errorf("compile embedded schema %s: %w", probeRequestSchemaFile, err)
	}
	return schema, nil
})

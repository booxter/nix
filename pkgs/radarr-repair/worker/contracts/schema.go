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

const MaxBlurayIdentifyRequestBytes = MaxProbeRequestBytes
const MaxBlurayIdentifyResponseBytes = 256 << 10
const MaxBlurayRemuxRequestBytes = 16 << 20
const MaxBlurayRemuxResponseBytes = MaxProbeResponseBytes

// MaxJoinRequestBytes bounds the worst-case 128-part request with 32 full-size
// path components per part.
const MaxJoinRequestBytes = 2 << 20

// MaxJoinResponseBytes accommodates the same bounded media evidence returned
// by a probe response.
const MaxJoinResponseBytes = 4 << 20

const (
	wireTypesSchemaFile                  = "v1/wire-types.schema.json"
	wireTypesSchemaLocation              = "file:///radarr-repair-worker/contracts/v1/wire-types.schema.json"
	blurayIdentifyRequestSchemaFile      = "v1/bluray-identify-request.schema.json"
	blurayIdentifyRequestSchemaLocation  = "file:///radarr-repair-worker/contracts/v1/bluray-identify-request.schema.json"
	blurayIdentifyResponseSchemaFile     = "v1/bluray-identify-response.schema.json"
	blurayIdentifyResponseSchemaLocation = "file:///radarr-repair-worker/contracts/v1/bluray-identify-response.schema.json"
	blurayRemuxRequestSchemaFile         = "v1/bluray-remux-request.schema.json"
	blurayRemuxRequestSchemaLocation     = "file:///radarr-repair-worker/contracts/v1/bluray-remux-request.schema.json"
	blurayRemuxResponseSchemaFile        = "v1/bluray-remux-response.schema.json"
	blurayRemuxResponseSchemaLocation    = "file:///radarr-repair-worker/contracts/v1/bluray-remux-response.schema.json"
	probeRequestSchemaFile               = "v1/probe-request.schema.json"
	probeRequestSchemaLocation           = "file:///radarr-repair-worker/contracts/v1/probe-request.schema.json"
	mediaEvidenceSchemaFile              = "v1/media-evidence.schema.json"
	mediaEvidenceSchemaLocation          = "file:///radarr-repair-worker/contracts/v1/media-evidence.schema.json"
	probeResponseSchemaFile              = "v1/probe-response.schema.json"
	probeResponseSchemaLocation          = "file:///radarr-repair-worker/contracts/v1/probe-response.schema.json"
	joinRequestSchemaFile                = "v1/join-request.schema.json"
	joinRequestSchemaLocation            = "file:///radarr-repair-worker/contracts/v1/join-request.schema.json"
	joinResponseSchemaFile               = "v1/join-response.schema.json"
	joinResponseSchemaLocation           = "file:///radarr-repair-worker/contracts/v1/join-response.schema.json"
)

//go:embed v1/*.schema.json
var schemaFiles embed.FS

type schemaResource struct {
	fileName string
	location string
}

var (
	wireTypesSchemaResource = schemaResource{
		fileName: wireTypesSchemaFile,
		location: wireTypesSchemaLocation,
	}
	mediaEvidenceSchemaResource = schemaResource{
		fileName: mediaEvidenceSchemaFile,
		location: mediaEvidenceSchemaLocation,
	}
)

var probeRequestSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(
		probeRequestSchemaFile,
		probeRequestSchemaLocation,
		wireTypesSchemaResource,
	)
})

var blurayIdentifyRequestSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(
		blurayIdentifyRequestSchemaFile,
		blurayIdentifyRequestSchemaLocation,
		wireTypesSchemaResource,
	)
})

var blurayIdentifyResponseSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(
		blurayIdentifyResponseSchemaFile,
		blurayIdentifyResponseSchemaLocation,
		wireTypesSchemaResource,
	)
})

var blurayRemuxRequestSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(
		blurayRemuxRequestSchemaFile,
		blurayRemuxRequestSchemaLocation,
		wireTypesSchemaResource,
	)
})

var blurayRemuxResponseSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(
		blurayRemuxResponseSchemaFile,
		blurayRemuxResponseSchemaLocation,
		wireTypesSchemaResource,
		mediaEvidenceSchemaResource,
	)
})

var probeResponseSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(
		probeResponseSchemaFile,
		probeResponseSchemaLocation,
		wireTypesSchemaResource,
		mediaEvidenceSchemaResource,
	)
})

var joinRequestSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(
		joinRequestSchemaFile,
		joinRequestSchemaLocation,
		wireTypesSchemaResource,
	)
})

var joinResponseSchema = sync.OnceValues(func() (*jsonschema.Schema, error) {
	return compileSchema(
		joinResponseSchemaFile,
		joinResponseSchemaLocation,
		wireTypesSchemaResource,
		mediaEvidenceSchemaResource,
	)
})

func compileSchema(
	fileName string,
	location string,
	references ...schemaResource,
) (*jsonschema.Schema, error) {
	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft2020)
	compiler.AssertFormat()
	for _, reference := range references {
		if err := registerSchema(compiler, reference.fileName, reference.location); err != nil {
			return nil, err
		}
	}
	if err := registerSchema(compiler, fileName, location); err != nil {
		return nil, err
	}
	schema, err := compiler.Compile(location)
	if err != nil {
		return nil, fmt.Errorf("compile embedded schema %s: %w", fileName, err)
	}
	return schema, nil
}

func registerSchema(compiler *jsonschema.Compiler, fileName string, location string) error {
	data, err := schemaFiles.ReadFile(fileName)
	if err != nil {
		return fmt.Errorf("read embedded schema %s: %w", fileName, err)
	}
	document, err := jsonschema.UnmarshalJSON(bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("parse embedded schema %s: %w", fileName, err)
	}
	if err := compiler.AddResource(location, document); err != nil {
		return fmt.Errorf("register embedded schema %s: %w", fileName, err)
	}
	return nil
}

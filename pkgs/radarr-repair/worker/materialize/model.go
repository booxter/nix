package materialize

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const (
	SchemaVersion                 = "media-repair-worker/v1"
	OperationMaterializeTar       = "materialize_tar_audio_v1"
	MaxRequestBytes         int64 = 64 << 10
	MaxResponseBytes              = 8 << 20
)

var opaqueID = regexp.MustCompile(`^[a-z][a-z0-9_:-]{0,127}$`)
var fingerprint = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

type Request struct {
	SchemaVersion       string   `json:"schema_version"`
	RequestID           string   `json:"request_id"`
	Operation           string   `json:"operation"`
	RootID              string   `json:"root_id"`
	ArchiveComponents   []string `json:"archive_path_components"`
	ExpectedFingerprint string   `json:"expected_fingerprint"`
	WorkspaceID         string   `json:"workspace_id"`
}

type Artifact struct {
	ArtifactID     string                   `json:"artifact_id"`
	PathComponents []string                 `json:"path_components"`
	RelativePath   string                   `json:"relative_path"`
	SizeBytes      int64                    `json:"size_bytes"`
	Fingerprint    string                   `json:"fingerprint"`
	Evidence       workercontracts.Evidence `json:"evidence"`
}

type Success struct {
	SchemaVersion       string     `json:"schema_version"`
	RequestID           string     `json:"request_id"`
	Operation           string     `json:"operation"`
	RootID              string     `json:"root_id"`
	WorkspaceComponents []string   `json:"workspace_path_components"`
	Artifacts           []Artifact `json:"artifacts"`
}

type Failure struct {
	SchemaVersion string `json:"schema_version"`
	RequestID     string `json:"request_id"`
	Operation     string `json:"operation"`
	Reason        string `json:"reason"`
}

type Response struct {
	Status  string   `json:"status"`
	Success *Success `json:"success,omitempty"`
	Failure *Failure `json:"failure,omitempty"`
}

func DecodeRequest(data []byte) (Request, error) {
	var request Request
	if err := decodeStrict(data, &request); err != nil {
		return Request{}, err
	}
	if err := validateRequest(request); err != nil {
		return Request{}, err
	}
	return request, nil
}

func EncodeResponse(response Response) ([]byte, error) {
	if err := validateResponse(response); err != nil {
		return nil, err
	}
	return json.Marshal(response)
}

func decodeStrict(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("decode materialization request: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("decode materialization request: multiple JSON values")
		}
		return fmt.Errorf("decode materialization request trailing data: %w", err)
	}
	return nil
}

func validateRequest(request Request) error {
	if request.SchemaVersion != SchemaVersion || request.Operation != OperationMaterializeTar {
		return fmt.Errorf("unsupported materialization contract")
	}
	if !opaqueID.MatchString(request.RequestID) || !opaqueID.MatchString(request.RootID) ||
		!opaqueID.MatchString(request.WorkspaceID) || !fingerprint.MatchString(request.ExpectedFingerprint) {
		return fmt.Errorf("invalid materialization identity")
	}
	if !validComponents(request.ArchiveComponents) {
		return fmt.Errorf("invalid archive path")
	}
	return nil
}

func validateResponse(response Response) error {
	if response.Status == "ok" && response.Success != nil && response.Failure == nil {
		return nil
	}
	if response.Status == "failed" && response.Success == nil && response.Failure != nil {
		return nil
	}
	return fmt.Errorf("materialization response must contain exactly one result")
}

func validComponents(components []string) bool {
	if len(components) == 0 || len(components) > 64 {
		return false
	}
	for _, component := range components {
		if component == "" || component == "." || component == ".." ||
			strings.ContainsAny(component, "/\\\x00") {
			return false
		}
	}
	return true
}

package materialize

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

const FailureNoSupportedAudio = "no_supported_audio"

const artifactIdentityDomain = "media-repair-artifact-v2\x00"

func ArtifactID(relativePath string, contentFingerprint string) string {
	digest := sha256.Sum256([]byte(
		artifactIdentityDomain + relativePath + "\x00" + contentFingerprint,
	))
	return "artifact:" + hex.EncodeToString(digest[:])
}

type Rejection struct {
	Reason string
}

func (rejection *Rejection) Error() string {
	return "media worker rejected materialization: " + rejection.Reason
}

func IsNoSupportedAudio(err error) bool {
	var rejection *Rejection
	return errors.As(err, &rejection) && rejection.Reason == FailureNoSupportedAudio
}

const (
	SchemaVersion                       = "media-repair-worker/v1"
	OperationMaterializeTar             = "materialize_tar_audio_v1"
	OperationMaterializeDirectory       = "materialize_directory_audio_v1"
	OperationMaterializeTarVideo        = "materialize_tar_video_v1"
	MaxRequestBytes               int64 = 64 << 10
	MaxResponseBytes                    = 8 << 20
)

var opaqueID = regexp.MustCompile(`^[a-z][a-z0-9_:-]{0,127}$`)
var fingerprint = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

type Request struct {
	SchemaVersion       string   `json:"schema_version"`
	RequestID           string   `json:"request_id"`
	Operation           string   `json:"operation"`
	RootID              string   `json:"root_id"`
	SourceComponents    []string `json:"source_path_components"`
	ExpectedFingerprint string   `json:"expected_fingerprint,omitempty"`
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
	SourceFingerprint   string     `json:"source_fingerprint"`
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

func EncodeRequest(request Request) ([]byte, error) {
	if err := validateRequest(request); err != nil {
		return nil, err
	}
	return json.Marshal(request)
}

func DecodeResponse(data []byte) (Response, error) {
	var response Response
	if err := decodeStrict(data, &response); err != nil {
		return Response{}, err
	}
	if err := validateResponse(response); err != nil {
		return Response{}, err
	}
	return response, nil
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
	if request.SchemaVersion != SchemaVersion || !validOperation(request.Operation) {
		return fmt.Errorf("unsupported materialization contract")
	}
	if !opaqueID.MatchString(request.RequestID) || !opaqueID.MatchString(request.RootID) ||
		!opaqueID.MatchString(request.WorkspaceID) {
		return fmt.Errorf("invalid materialization identity")
	}
	if !validComponents(request.SourceComponents) {
		return fmt.Errorf("invalid source path")
	}
	if request.Operation == OperationMaterializeTar ||
		request.Operation == OperationMaterializeTarVideo {
		if !fingerprint.MatchString(request.ExpectedFingerprint) {
			return fmt.Errorf("invalid materialization identity")
		}
	} else if request.ExpectedFingerprint != "" {
		return fmt.Errorf("directory materialization cannot supply a fingerprint")
	}
	return nil
}

func validateResponse(response Response) error {
	if response.Status == "ok" && response.Success != nil && response.Failure == nil {
		if response.Success.SchemaVersion != SchemaVersion ||
			!validOperation(response.Success.Operation) ||
			!opaqueID.MatchString(response.Success.RequestID) ||
			!opaqueID.MatchString(response.Success.RootID) ||
			!fingerprint.MatchString(response.Success.SourceFingerprint) ||
			!validComponents(response.Success.WorkspaceComponents) ||
			len(response.Success.Artifacts) == 0 {
			return fmt.Errorf("materialization success is incomplete")
		}
		seen := make(map[string]struct{}, len(response.Success.Artifacts))
		for _, artifact := range response.Success.Artifacts {
			if !opaqueID.MatchString(artifact.ArtifactID) ||
				!fingerprint.MatchString(artifact.Fingerprint) || artifact.SizeBytes <= 0 ||
				artifact.RelativePath == "" || !validComponents(artifact.PathComponents) {
				return fmt.Errorf("materialization artifact is incomplete")
			}
			if _, duplicate := seen[artifact.ArtifactID]; duplicate {
				return fmt.Errorf("materialization artifact is duplicated")
			}
			seen[artifact.ArtifactID] = struct{}{}
		}
		return nil
	}
	if response.Status == "failed" && response.Success == nil && response.Failure != nil {
		if response.Failure.SchemaVersion != SchemaVersion ||
			!validOperation(response.Failure.Operation) ||
			!opaqueID.MatchString(response.Failure.RequestID) || response.Failure.Reason == "" {
			return fmt.Errorf("materialization failure is incomplete")
		}
		return nil
	}
	return fmt.Errorf("materialization response must contain exactly one result")
}

func validOperation(operation string) bool {
	switch operation {
	case OperationMaterializeTar,
		OperationMaterializeDirectory,
		OperationMaterializeTarVideo:
		return true
	default:
		return false
	}
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

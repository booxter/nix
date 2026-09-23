package materialize

import (
	"reflect"
	"testing"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

func TestRequestAndResponseRoundTrip(t *testing.T) {
	t.Parallel()
	request := Request{
		SchemaVersion: SchemaVersion, RequestID: "request:one",
		Operation: OperationMaterializeTar, RootID: "usenet",
		SourceComponents:    []string{"Album", "audio.tar"},
		ExpectedFingerprint: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		WorkspaceID:         "workspace:one",
	}
	data, err := EncodeRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	decodedRequest, err := DecodeRequest(data)
	if err != nil || !reflect.DeepEqual(decodedRequest, request) {
		t.Fatalf("request = %#v, error = %v", decodedRequest, err)
	}

	response := Response{Status: "ok", Success: &Success{
		SchemaVersion: SchemaVersion, RequestID: request.RequestID,
		Operation: OperationMaterializeTar, RootID: request.RootID,
		SourceFingerprint:   request.ExpectedFingerprint,
		WorkspaceComponents: []string{".media-repair", "workspaces", request.WorkspaceID},
		Artifacts: []Artifact{{
			ArtifactID: "artifact:one", PathComponents: []string{
				".media-repair", "workspaces", request.WorkspaceID, "01.flac",
			},
			RelativePath: "01.flac", SizeBytes: 100,
			Fingerprint: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			Evidence:    workercontracts.Evidence{},
		}},
	}}
	data, err = EncodeResponse(response)
	if err != nil {
		t.Fatal(err)
	}
	decodedResponse, err := DecodeResponse(data)
	if err != nil || !reflect.DeepEqual(decodedResponse, response) {
		t.Fatalf("response = %#v, error = %v", decodedResponse, err)
	}
}

func TestDirectoryRequestRoundTrip(t *testing.T) {
	t.Parallel()
	request := Request{
		SchemaVersion: SchemaVersion, RequestID: "request:directory",
		Operation: OperationMaterializeDirectory, RootID: "downloads",
		SourceComponents: []string{"Artist", "Album"}, WorkspaceID: "workspace:directory",
	}
	data, err := EncodeRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeRequest(data)
	if err != nil || !reflect.DeepEqual(decoded, request) {
		t.Fatalf("request = %#v, error = %v", decoded, err)
	}
	request.ExpectedFingerprint = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if _, err := EncodeRequest(request); err == nil {
		t.Fatal("directory request with caller fingerprint was accepted")
	}
}

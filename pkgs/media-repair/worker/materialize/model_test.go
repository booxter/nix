package materialize

import (
	"errors"
	"fmt"
	"reflect"
	"testing"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

func TestUnsupportedSourceRejections(t *testing.T) {
	t.Parallel()
	for _, reason := range []string{
		FailureNoSupportedAudio,
		FailureInvalidArchive,
		FailureEncryptedArchive,
		FailureInvalidCueSheet,
	} {
		err := fmt.Errorf("materialize source: %w", &Rejection{Reason: reason})
		if !IsUnsupportedSource(err) {
			t.Fatalf("reason %q was not classified as an unsupported source", reason)
		}
	}
	for _, err := range []error{
		errors.New("worker unavailable"),
		&Rejection{Reason: "timeout"},
		&Rejection{Reason: "fingerprint_mismatch"},
	} {
		if IsUnsupportedSource(err) {
			t.Fatalf("error %q was classified as an unsupported source", err)
		}
	}
}

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

func TestVideoArchiveRequestRoundTrip(t *testing.T) {
	t.Parallel()
	request := Request{
		SchemaVersion: SchemaVersion, RequestID: "request:video",
		Operation: OperationMaterializeTarVideo, RootID: "downloads",
		SourceComponents:    []string{"Movie", "video.tar"},
		ExpectedFingerprint: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		WorkspaceID:         "workspace:video",
	}
	data, err := EncodeRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeRequest(data)
	if err != nil || !reflect.DeepEqual(decoded, request) {
		t.Fatalf("request = %#v, error = %v", decoded, err)
	}
}

func TestArtifactIDIncludesRelativePath(t *testing.T) {
	t.Parallel()
	fingerprint := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	first := ArtifactID("disc-1/01.flac", fingerprint)
	second := ArtifactID("disc-2/01.flac", fingerprint)
	if first == second || first != ArtifactID("disc-1/01.flac", fingerprint) {
		t.Fatalf("artifact IDs are not stable and path-specific: %q %q", first, second)
	}
}

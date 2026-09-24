package bluraypublish

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/booxter/nix-config/media-repair/worker/blurayrequest"
	"github.com/booxter/nix-config/media-repair/worker/bluraystage"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
)

func TestPublishMovesVerifiedRemuxBesideDiscAndRecovers(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	if err := os.Mkdir(filepath.Join(directory, "Example.Movie"), 0o700); err != nil {
		t.Fatal(err)
	}
	root, err := mediafile.NewRootSet(map[string]string{"root:downloads": directory})
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	request := publishRequest(t)
	request.ArtifactID, err = bluraystage.ArtifactID(
		blurayrequest.Specification(request.StageRequest),
	)
	if err != nil {
		t.Fatal(err)
	}
	artifact, err := root.CreateStaged(
		"root:downloads", request.ArtifactID, workercontracts.OutputContainerMKV, 1,
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := artifact.File().Write([]byte("verified remux")); err != nil {
		t.Fatal(err)
	}
	request.ArtifactFingerprint, _, err = artifact.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if err := artifact.Retain(); err != nil {
		t.Fatal(err)
	}
	executor, err := NewExecutor(root)
	if err != nil {
		t.Fatal(err)
	}
	first := executor.Execute(context.Background(), request)
	if first.Success == nil || first.Failure != nil ||
		len(first.Success.PathComponents) != 2 ||
		first.Success.PathComponents[0] != "Example.Movie" {
		t.Fatalf("published remux = %#v", first)
	}
	path := filepath.Join(append([]string{directory}, first.Success.PathComponents...)...)
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "verified remux" {
		t.Fatalf("published output = %q, error = %v", data, err)
	}
	second := executor.Execute(context.Background(), request)
	if second.Success == nil || !reflect.DeepEqual(second.Success, first.Success) {
		t.Fatalf("recovered publish = %#v", second)
	}
	if _, err := workercontracts.EncodeBlurayPublishResponse(second); err != nil {
		t.Fatalf("encode publication response: %v", err)
	}
}

func TestPublishRejectsDifferentArtifactIdentity(t *testing.T) {
	t.Parallel()
	request := publishRequest(t)
	root, err := mediafile.NewRootSet(map[string]string{"root:downloads": t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	executor, err := NewExecutor(root)
	if err != nil {
		t.Fatal(err)
	}
	response := executor.Execute(context.Background(), request)
	if response.Failure == nil || response.Failure.Reason != "invalid_request" {
		t.Fatalf("mismatched publish = %#v", response)
	}
}

func publishRequest(t *testing.T) workercontracts.BlurayPublishRequestV1 {
	t.Helper()
	data, err := os.ReadFile("../contracts/v1/examples/bluray-publish-request.json")
	if err != nil {
		t.Fatal(err)
	}
	request, err := workercontracts.DecodeBlurayPublishRequest(data)
	if err != nil {
		t.Fatal(err)
	}
	return request
}

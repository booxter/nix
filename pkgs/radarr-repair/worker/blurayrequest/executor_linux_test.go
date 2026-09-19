package blurayrequest

import (
	"context"
	"os"
	"reflect"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/worker/bluraystage"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
)

type recordingStager struct {
	spec   bluraystage.Specification
	result bluraystage.Result
	err    error
}

func (stager *recordingStager) StageOrRecover(
	_ context.Context,
	spec bluraystage.Specification,
) (bluraystage.Result, error) {
	stager.spec = spec
	return stager.result, stager.err
}

func TestExecutorPassesBoundedRemuxSpecification(t *testing.T) {
	t.Parallel()
	request := remuxRequest(t)
	duration := int64(7_200_000)
	stager := &recordingStager{result: bluraystage.Result{
		ArtifactID:  "artifact:remux:01",
		Fingerprint: "sha256:4444444444444444444444444444444444444444444444444444444444444444",
		SizeBytes:   8_390_000_000,
		Evidence: controller.ProbeEvidence{
			Format: controller.ProbeFormat{
				Names: []string{"matroska", "webm"}, DurationMS: &duration,
			},
		},
	}}
	executor, err := NewExecutor(stager)
	if err != nil {
		t.Fatal(err)
	}
	response := executor.Execute(context.Background(), request)
	if response.Success == nil || response.Failure != nil ||
		response.Success.ArtifactID != stager.result.ArtifactID {
		t.Fatalf("remux response = %#v", response)
	}
	if stager.spec.CaseID != request.CaseID ||
		stager.spec.Playlist.ExpectedFingerprint != request.Playlist.ExpectedFingerprint ||
		len(stager.spec.Clips) != 1 ||
		!reflect.DeepEqual(stager.spec.Clips[0].PathComponents, request.Clips[0].PathComponents) ||
		stager.spec.ExpectedTracks[0].Kind != "video" {
		t.Fatalf("worker remux specification = %#v", stager.spec)
	}
	if _, err := workercontracts.EncodeBlurayRemuxResponse(response); err != nil {
		t.Fatalf("encode successful remux response: %v", err)
	}
}

func TestExecutorRedactsWorkerFailure(t *testing.T) {
	t.Parallel()
	stager := &recordingStager{
		err: &mediafile.Failure{Kind: mediafile.FailureFingerprintMismatch},
	}
	executor, err := NewExecutor(stager)
	if err != nil {
		t.Fatal(err)
	}
	response := executor.Execute(context.Background(), remuxRequest(t))
	if response.Failure == nil || response.Success != nil ||
		response.Failure.Reason != "fingerprint_mismatch" {
		t.Fatalf("remux failure = %#v", response)
	}
	if _, err := workercontracts.EncodeBlurayRemuxResponse(response); err != nil {
		t.Fatalf("encode remux failure: %v", err)
	}
}

func remuxRequest(t *testing.T) workercontracts.BlurayRemuxRequestV1 {
	t.Helper()
	data, err := os.ReadFile("../contracts/v1/examples/bluray-remux-request.json")
	if err != nil {
		t.Fatal(err)
	}
	request, err := workercontracts.DecodeBlurayRemuxRequest(data)
	if err != nil {
		t.Fatal(err)
	}
	return request
}

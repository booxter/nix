package workerprobe

import (
	"reflect"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

func TestSuccessResponseBuildsWireEnvelope(t *testing.T) {
	t.Parallel()

	duration := int64(2_000)
	response := SuccessResponse("request:01", controller.ProbeEvidence{
		Format: controller.ProbeFormat{DurationMS: &duration},
	})
	if response.Kind != workercontracts.ProbeResponseSucceeded || response.Success == nil ||
		response.Failure != nil || response.RequestID() != "request:01" {
		t.Fatalf("response = %#v", response)
	}
	if response.Success.SchemaVersion != workercontracts.RadarrRepairWorkerV1 ||
		response.Success.Operation != workercontracts.ProbeV1 ||
		response.Success.Status != workercontracts.Ok ||
		response.Success.Evidence.Format.DurationMS == nil ||
		*response.Success.Evidence.Format.DurationMS != duration {
		t.Fatalf("response = %#v", response.Success)
	}
	assertEncodes(t, response)
}

func TestFailureResponseBuildsWireEnvelope(t *testing.T) {
	t.Parallel()

	response := FailureResponse("request:02", workercontracts.FingerprintMismatch)
	if response.Kind != workercontracts.ProbeResponseFailed || response.Success != nil ||
		response.Failure == nil || response.RequestID() != "request:02" {
		t.Fatalf("response = %#v", response)
	}
	want := workercontracts.ProbeFailureResponseV1{
		Operation:     workercontracts.ProbeV1,
		Reason:        workercontracts.FingerprintMismatch,
		RequestID:     "request:02",
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
		Status:        workercontracts.Failed,
	}
	if !reflect.DeepEqual(*response.Failure, want) {
		t.Fatalf("failure = %#v, want %#v", *response.Failure, want)
	}
	assertEncodes(t, response)
}

func assertEncodes(t *testing.T, response workercontracts.ProbeResponseV1) {
	t.Helper()
	encoded, err := workercontracts.EncodeProbeResponse(response)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := workercontracts.DecodeProbeResponse(encoded); err != nil {
		t.Fatalf("decode encoded response: %v", err)
	}
}

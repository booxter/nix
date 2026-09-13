package workercontracts

import "testing"

func TestJoinRequestExamplesDecodeAndRoundTrip(t *testing.T) {
	t.Parallel()

	t.Run("stage", func(t *testing.T) {
		t.Parallel()
		request, err := DecodeStageJoinRequest(
			readFixture(t, "v1/examples/join-stage-request.json"),
		)
		if err != nil {
			t.Fatal(err)
		}
		if request.RequestID != "request:join:01" ||
			request.ExecutionID != "execution:join:01" ||
			request.OutputContainer != OutputContainerMKV ||
			len(request.Parts) != 2 ||
			request.Parts[0].FileID != "file:part:01" ||
			request.Parts[1].FileID != "file:part:02" {
			t.Fatalf("stage request = %#v", request)
		}
		encoded, err := EncodeStageJoinRequest(request)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := DecodeStageJoinRequest(encoded); err != nil {
			t.Fatalf("decode round trip: %v", err)
		}
	})

	t.Run("publish", func(t *testing.T) {
		t.Parallel()
		request, err := DecodePublishRequest(
			readFixture(t, "v1/examples/join-publish-request.json"),
		)
		if err != nil {
			t.Fatal(err)
		}
		if request.RequestID != "request:publish:01" ||
			request.ArtifactID != "artifact:join:01" {
			t.Fatalf("publish request = %#v", request)
		}
		encoded, err := EncodePublishRequest(request)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := DecodePublishRequest(encoded); err != nil {
			t.Fatalf("decode round trip: %v", err)
		}
	})

	t.Run("discard", func(t *testing.T) {
		t.Parallel()
		request, err := DecodeDiscardRequest(
			readFixture(t, "v1/examples/join-discard-request.json"),
		)
		if err != nil {
			t.Fatal(err)
		}
		if request.RequestID != "request:discard:01" ||
			request.ArtifactID != "artifact:join:01" {
			t.Fatalf("discard request = %#v", request)
		}
		encoded, err := EncodeDiscardRequest(request)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := DecodeDiscardRequest(encoded); err != nil {
			t.Fatalf("decode round trip: %v", err)
		}
	})
}

func TestJoinResponseExamplesDecodeAndRoundTrip(t *testing.T) {
	t.Parallel()

	t.Run("stage success", func(t *testing.T) {
		t.Parallel()
		response, err := DecodeStageJoinResponse(
			readFixture(t, "v1/examples/join-stage-response-ok.json"),
		)
		if err != nil {
			t.Fatal(err)
		}
		if response.Kind != ProbeResponseSucceeded ||
			response.RequestID() != "request:join:01" ||
			response.Success == nil || response.Failure != nil ||
			response.Success.ArtifactID != "artifact:join:01" ||
			len(response.Success.Evidence.Streams) != 1 {
			t.Fatalf("stage response = %#v", response)
		}
		encoded, err := EncodeStageJoinResponse(response)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := DecodeStageJoinResponse(encoded); err != nil {
			t.Fatalf("decode round trip: %v", err)
		}
	})

	t.Run("stage failure", func(t *testing.T) {
		t.Parallel()
		response, err := DecodeStageJoinResponse(
			readFixture(t, "v1/examples/join-stage-response-failed.json"),
		)
		if err != nil {
			t.Fatal(err)
		}
		if response.Kind != ProbeResponseFailed || response.Success != nil ||
			response.Failure == nil ||
			response.Failure.Reason != StageJoinFingerprintMismatch {
			t.Fatalf("stage response = %#v", response)
		}
		encoded, err := EncodeStageJoinResponse(response)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := DecodeStageJoinResponse(encoded); err != nil {
			t.Fatalf("decode round trip: %v", err)
		}
	})

	t.Run("publish success", func(t *testing.T) {
		t.Parallel()
		response, err := DecodePublishResponse(
			readFixture(t, "v1/examples/join-publish-response-ok.json"),
		)
		if err != nil {
			t.Fatal(err)
		}
		if response.Kind != ProbeResponseSucceeded ||
			response.RequestID() != "request:publish:01" ||
			response.Success == nil || response.Failure != nil ||
			len(response.Success.PathComponents) != 2 {
			t.Fatalf("publish response = %#v", response)
		}
		encoded, err := EncodePublishResponse(response)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := DecodePublishResponse(encoded); err != nil {
			t.Fatalf("decode round trip: %v", err)
		}
	})

	t.Run("publish failure", func(t *testing.T) {
		t.Parallel()
		response, err := DecodePublishResponse(
			readFixture(t, "v1/examples/join-publish-response-failed.json"),
		)
		if err != nil {
			t.Fatal(err)
		}
		if response.Kind != ProbeResponseFailed || response.Success != nil ||
			response.Failure == nil ||
			response.Failure.Reason != PublishDestinationExists {
			t.Fatalf("publish response = %#v", response)
		}
	})

	t.Run("discard success", func(t *testing.T) {
		t.Parallel()
		response, err := DecodeDiscardResponse(
			readFixture(t, "v1/examples/join-discard-response-ok.json"),
		)
		if err != nil {
			t.Fatal(err)
		}
		if response.Kind != ProbeResponseSucceeded ||
			response.RequestID() != "request:discard:01" ||
			response.Success == nil || response.Failure != nil {
			t.Fatalf("discard response = %#v", response)
		}
		encoded, err := EncodeDiscardResponse(response)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := DecodeDiscardResponse(encoded); err != nil {
			t.Fatalf("decode round trip: %v", err)
		}
	})

	t.Run("discard failure", func(t *testing.T) {
		t.Parallel()
		response, err := DecodeDiscardResponse(
			readFixture(t, "v1/examples/join-discard-response-failed.json"),
		)
		if err != nil {
			t.Fatal(err)
		}
		if response.Kind != ProbeResponseFailed || response.Success != nil ||
			response.Failure == nil ||
			response.Failure.Reason != DiscardArtifactPublished {
			t.Fatalf("discard response = %#v", response)
		}
	})
}

func TestJoinContractsRejectPathAuthority(t *testing.T) {
	t.Parallel()

	if _, err := DecodeStageJoinRequest(
		readFixture(t, "../contract-tests/v1/join-request-stage-parent-path.json"),
	); err == nil {
		t.Fatal("stage request with a parent path was accepted")
	}
	if _, err := DecodePublishRequest(
		readFixture(t, "../contract-tests/v1/join-request-publish-path.json"),
	); err == nil {
		t.Fatal("publish request with a caller-selected path was accepted")
	}
	if _, err := DecodeStageJoinResponse(
		readFixture(t, "../contract-tests/v1/join-response-private-stage-path.json"),
	); err == nil {
		t.Fatal("stage response exposing a private path was accepted")
	}
}

func TestJoinDecodersRejectAnotherOperation(t *testing.T) {
	t.Parallel()

	if _, err := DecodeDiscardRequest(
		readFixture(t, "v1/examples/join-publish-request.json"),
	); err == nil {
		t.Fatal("publish request decoded as discard")
	}
	if _, err := DecodeDiscardResponse(
		readFixture(t, "v1/examples/join-publish-response-ok.json"),
	); err == nil {
		t.Fatal("publish response decoded as discard")
	}
}

func TestEncodeJoinResponseRejectsInvalidEnvelope(t *testing.T) {
	t.Parallel()

	success, err := DecodeStageJoinResponse(
		readFixture(t, "v1/examples/join-stage-response-ok.json"),
	)
	if err != nil {
		t.Fatal(err)
	}
	failure, err := DecodeStageJoinResponse(
		readFixture(t, "v1/examples/join-stage-response-failed.json"),
	)
	if err != nil {
		t.Fatal(err)
	}
	for _, response := range []StageJoinResponseV1{
		{},
		{Kind: ProbeResponseSucceeded},
		{Kind: ProbeResponseFailed},
		{
			Kind:    ProbeResponseSucceeded,
			Success: success.Success,
			Failure: failure.Failure,
		},
	} {
		if _, err := EncodeStageJoinResponse(response); err == nil {
			t.Fatal("invalid stage response envelope was encoded")
		}
	}
}

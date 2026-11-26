package workercontracts

import (
	"reflect"
	"testing"
)

func TestBlurayIdentificationExamplesRoundTrip(t *testing.T) {
	t.Parallel()

	request, err := DecodeBlurayIdentifyRequest(
		readFixture(t, "v1/examples/bluray-identify-request.json"),
	)
	if err != nil {
		t.Fatal(err)
	}
	encodedRequest, err := EncodeBlurayIdentifyRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	decodedRequest, err := DecodeBlurayIdentifyRequest(encodedRequest)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(decodedRequest, request) {
		t.Fatalf("request round trip = %#v, want %#v", decodedRequest, request)
	}

	for _, fixture := range []string{
		"v1/examples/bluray-identify-response-ok.json",
		"v1/examples/bluray-identify-response-failed.json",
	} {
		response, err := DecodeBlurayIdentifyResponse(readFixture(t, fixture))
		if err != nil {
			t.Fatal(err)
		}
		if response.RequestID() != request.RequestID {
			t.Errorf("%s: mismatched request ID", fixture)
		}
		encodedResponse, err := EncodeBlurayIdentifyResponse(response)
		if err != nil {
			t.Fatal(err)
		}
		decodedResponse, err := DecodeBlurayIdentifyResponse(encodedResponse)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(decodedResponse, response) {
			t.Fatalf("%s: response round trip = %#v, want %#v", fixture, decodedResponse, response)
		}
	}
}

func TestBlurayIdentificationRejectsInvalidClipName(t *testing.T) {
	t.Parallel()

	response, err := DecodeBlurayIdentifyResponse(
		readFixture(t, "v1/examples/bluray-identify-response-ok.json"),
	)
	if err != nil {
		t.Fatal(err)
	}
	response.Success.ClipNames[0] = "../other.m2ts"
	if _, err := EncodeBlurayIdentifyResponse(response); err == nil {
		t.Fatal("accepted a clip name outside the Blu-ray stream directory")
	}
}

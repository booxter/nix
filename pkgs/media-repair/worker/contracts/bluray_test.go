package workercontracts

import "testing"

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
	if _, err := DecodeBlurayIdentifyRequest(encodedRequest); err != nil {
		t.Fatal(err)
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
		if _, err := DecodeBlurayIdentifyResponse(encodedResponse); err != nil {
			t.Fatal(err)
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

func TestBlurayRemuxExamplesRoundTrip(t *testing.T) {
	t.Parallel()
	request, err := DecodeBlurayRemuxRequest(
		readFixture(t, "v1/examples/bluray-remux-request.json"),
	)
	if err != nil {
		t.Fatal(err)
	}
	encodedRequest, err := EncodeBlurayRemuxRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeBlurayRemuxRequest(encodedRequest); err != nil {
		t.Fatal(err)
	}
	for _, fixture := range []string{
		"v1/examples/bluray-remux-response-ok.json",
		"v1/examples/bluray-remux-response-failed.json",
	} {
		response, err := DecodeBlurayRemuxResponse(readFixture(t, fixture))
		if err != nil {
			t.Fatal(err)
		}
		if response.RequestID() != request.RequestID {
			t.Errorf("%s: mismatched request ID", fixture)
		}
		encodedResponse, err := EncodeBlurayRemuxResponse(response)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := DecodeBlurayRemuxResponse(encodedResponse); err != nil {
			t.Fatal(err)
		}
	}
}

func TestBlurayRemuxRejectsUnsafePath(t *testing.T) {
	t.Parallel()
	request, err := DecodeBlurayRemuxRequest(
		readFixture(t, "v1/examples/bluray-remux-request.json"),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Clips[0].PathComponents[0] = ".."
	if _, err := EncodeBlurayRemuxRequest(request); err == nil {
		t.Fatal("accepted an unsafe Blu-ray clip path")
	}
}

func TestBlurayPublishExamplesRoundTrip(t *testing.T) {
	t.Parallel()
	request, err := DecodeBlurayPublishRequest(
		readFixture(t, "v1/examples/bluray-publish-request.json"),
	)
	if err != nil {
		t.Fatal(err)
	}
	encodedRequest, err := EncodeBlurayPublishRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeBlurayPublishRequest(encodedRequest); err != nil {
		t.Fatal(err)
	}
	for _, fixture := range []string{
		"v1/examples/bluray-publish-response-ok.json",
		"v1/examples/bluray-publish-response-failed.json",
	} {
		response, err := DecodeBlurayPublishResponse(readFixture(t, fixture))
		if err != nil {
			t.Fatal(err)
		}
		if response.RequestID() != request.RequestID {
			t.Errorf("%s: mismatched request ID", fixture)
		}
		encodedResponse, err := EncodeBlurayPublishResponse(response)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := DecodeBlurayPublishResponse(encodedResponse); err != nil {
			t.Fatal(err)
		}
	}
}

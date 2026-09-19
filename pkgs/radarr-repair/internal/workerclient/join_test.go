package workerclient

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/joinrequest"
	"github.com/booxter/nix-config/radarr-repair/worker/joinstate"
	"github.com/booxter/nix-config/radarr-repair/worker/mediaevidence"
)

const (
	testArtifactID          = "artifact:join:01"
	testArtifactFingerprint = "sha256:4444444444444444444444444444444444444444444444444444444444444444"
)

func TestClientStagesAuthorizedJoinThroughUnixSocket(t *testing.T) {
	t.Parallel()

	requests := make(chan workercontracts.StageJoinRequestV1, 1)
	socketPath := serveUnix(t, http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		stageRequest, err := readStageJoinRequest(request)
		if err != nil {
			http.Error(writer, "invalid request", http.StatusBadRequest)
			return
		}
		requests <- stageRequest
		// Staging can take longer than a normal probe request.
		time.Sleep(50 * time.Millisecond)
		evidence := completeEvidence()
		writeStageJoinResponse(writer, joinrequest.SuccessResponse(
			stageRequest.RequestID,
			testArtifactID,
			joinstate.StagedArtifact{
				Fingerprint: testArtifactFingerprint,
				SizeBytes:   *evidence.Format.SizeBytes,
				Evidence:    mediaevidence.FromProbe(evidence),
			},
		))
	}))
	client := testClient(t, socketPath, map[string]string{
		"root:downloads": "/downloads",
		"root:release":   "/downloads/Movie.Release",
	}, 10*time.Millisecond)
	authorized, paths := authorizedJoin()

	exchange, err := client.StageJoin(
		context.Background(),
		"execution:join:01",
		authorized,
		paths,
	)
	if err != nil {
		t.Fatal(err)
	}
	if exchange.Response.Kind != workercontracts.ProbeResponseSucceeded ||
		exchange.Response.Success == nil ||
		exchange.Response.Success.ArtifactID != testArtifactID {
		t.Fatalf("response = %#v", exchange.Response)
	}

	request := <-requests
	wantComponents := [][]string{{"CD1.mkv"}, {"CD2.mkv"}}
	gotComponents := make([][]string, len(request.Parts))
	for position, part := range request.Parts {
		gotComponents[position] = part.PathComponents
		if part.FileID != string(authorized.OrderedParts[position].FileID) ||
			part.ExpectedFingerprint != authorized.OrderedParts[position].Fingerprint.Fingerprint() {
			t.Fatalf("part %d = %#v", position, part)
		}
	}
	if request.RootID != "root:release" || !reflect.DeepEqual(gotComponents, wantComponents) ||
		request.ExecutionID != "execution:join:01" ||
		request.CaseID != authorized.CaseID || request.CapabilityID != authorized.CapabilityID ||
		request.ExpectedSourceBytes != authorized.SourceBytes ||
		request.ExpectedDurationMS != authorized.ExpectedDurationMS ||
		request.DurationToleranceMS != authorized.DurationToleranceMS ||
		request.ExpectedStreamCount != 1 ||
		request.OutputContainer != workercontracts.OutputContainerMKV {
		t.Fatalf("request = %#v", request)
	}
	if !reflect.DeepEqual(exchange.Request, request) {
		t.Fatalf("returned request = %#v, sent request = %#v", exchange.Request, request)
	}
}

func TestClientRequiresJoinPartsToShareAWorkerRoot(t *testing.T) {
	t.Parallel()

	client := testClient(t, "/run/worker.sock", map[string]string{
		"root:first":  "/first",
		"root:second": "/second",
	}, time.Second)
	authorized, paths := authorizedJoin()
	paths[authorized.OrderedParts[0].FileID] = "/first/CD1.mkv"
	paths[authorized.OrderedParts[1].FileID] = "/second/CD2.mkv"

	if _, err := client.StageJoin(
		context.Background(),
		"execution:join:01",
		authorized,
		paths,
	); err == nil {
		t.Fatal("join spanning worker roots was accepted")
	}
}

func TestClientPublishesAndDiscardsThroughUnixSocket(t *testing.T) {
	t.Parallel()

	requestedPaths := make(chan string, 2)
	socketPath := serveUnix(t, http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		requestedPaths <- request.URL.Path
		switch request.URL.Path {
		case publishPath:
			publishRequest, err := readPublishRequest(request)
			if err != nil {
				http.Error(writer, "invalid request", http.StatusBadRequest)
				return
			}
			writePublishResponse(writer, workercontracts.PublishResponseV1{
				Kind: workercontracts.ProbeResponseSucceeded,
				Success: &workercontracts.PublishSuccessResponseV1{
					ArtifactFingerprint: publishRequest.ArtifactFingerprint,
					ArtifactID:          publishRequest.ArtifactID,
					Operation:           workercontracts.PublishV1,
					PathComponents:      []string{"Movie.Release", "joined.mkv"},
					RequestID:           publishRequest.RequestID,
					RootID:              "root:downloads",
					SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
					Status:              workercontracts.Ok,
				},
			})
		case discardPath:
			discardRequest, err := readDiscardRequest(request)
			if err != nil {
				http.Error(writer, "invalid request", http.StatusBadRequest)
				return
			}
			writeDiscardResponse(writer, workercontracts.DiscardResponseV1{
				Kind: workercontracts.ProbeResponseFailed,
				Failure: &workercontracts.DiscardFailureResponseV1{
					Operation:     workercontracts.DiscardV1,
					Reason:        workercontracts.DiscardArtifactPublished,
					RequestID:     discardRequest.RequestID,
					SchemaVersion: workercontracts.RadarrRepairWorkerV1,
					Status:        workercontracts.Failed,
				},
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	client := testClient(t, socketPath, testRoots(), time.Second)
	artifact := Artifact{ID: testArtifactID, Fingerprint: testArtifactFingerprint}

	published, err := client.PublishJoin(context.Background(), artifact)
	if err != nil {
		t.Fatal(err)
	}
	if published.Success == nil || published.Success.ArtifactID != artifact.ID ||
		published.Success.ArtifactFingerprint != artifact.Fingerprint {
		t.Fatalf("publish response = %#v", published)
	}
	discarded, err := client.DiscardJoin(context.Background(), artifact)
	if err != nil {
		t.Fatal(err)
	}
	if discarded.Failure == nil ||
		discarded.Failure.Reason != workercontracts.DiscardArtifactPublished {
		t.Fatalf("discard response = %#v", discarded)
	}
	first := <-requestedPaths
	second := <-requestedPaths
	if first != publishPath || second != discardPath {
		t.Fatalf("request paths = %q, %q", first, second)
	}
}

func TestClientInspectsJoinThroughUnixSocket(t *testing.T) {
	t.Parallel()

	requests := make(chan workercontracts.InspectJoinRequestV1, 1)
	socketPath := serveUnix(t, http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		inspectRequest, err := readInspectJoinRequest(request)
		if err != nil {
			http.Error(writer, "invalid request", http.StatusBadRequest)
			return
		}
		requests <- inspectRequest
		writeInspectJoinResponse(writer, workercontracts.InspectJoinResponseV1{
			Kind: workercontracts.ProbeResponseSucceeded,
			Success: &workercontracts.InspectJoinSuccessResponseV1{
				Operation:     workercontracts.InspectJoinV1,
				RequestID:     inspectRequest.RequestID,
				SchemaVersion: workercontracts.RadarrRepairWorkerV1,
				State:         workercontracts.InspectJoinStaged,
				Status:        workercontracts.Ok,
			},
		})
	}))
	client := testClient(t, socketPath, testRoots(), time.Second)

	response, err := client.InspectJoin(context.Background(), "execution:join:01")
	if err != nil {
		t.Fatal(err)
	}
	if response.Success == nil || response.Failure != nil ||
		response.Success.State != workercontracts.InspectJoinStaged {
		t.Fatalf("response = %#v", response)
	}
	request := <-requests
	if request.ExecutionID != "execution:join:01" || request.RequestID != "request:1" {
		t.Fatalf("request = %#v", request)
	}
}

func TestClientRetainsJoinInspectionFailure(t *testing.T) {
	t.Parallel()

	socketPath := serveUnix(t, http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		inspectRequest, err := readInspectJoinRequest(request)
		if err != nil {
			http.Error(writer, "invalid request", http.StatusBadRequest)
			return
		}
		writeInspectJoinResponse(writer, workercontracts.InspectJoinResponseV1{
			Kind: workercontracts.ProbeResponseFailed,
			Failure: &workercontracts.InspectJoinFailureResponseV1{
				Operation:     workercontracts.InspectJoinV1,
				Reason:        workercontracts.InspectJoinInternal,
				RequestID:     inspectRequest.RequestID,
				SchemaVersion: workercontracts.RadarrRepairWorkerV1,
				Status:        workercontracts.Failed,
			},
		})
	}))
	client := testClient(t, socketPath, testRoots(), time.Second)

	response, err := client.InspectJoin(context.Background(), "execution:join:01")
	if err != nil {
		t.Fatal(err)
	}
	if response.Success != nil || response.Failure == nil ||
		response.Failure.Reason != workercontracts.InspectJoinInternal {
		t.Fatalf("response = %#v", response)
	}
}

func TestClientRejectsUncorrelatedJoinResponse(t *testing.T) {
	t.Parallel()

	socketPath := serveUnix(t, http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		if _, err := readPublishRequest(request); err != nil {
			http.Error(writer, "invalid request", http.StatusBadRequest)
			return
		}
		writePublishResponse(writer, workercontracts.PublishResponseV1{
			Kind: workercontracts.ProbeResponseFailed,
			Failure: &workercontracts.PublishFailureResponseV1{
				Operation:     workercontracts.PublishV1,
				Reason:        workercontracts.PublishArtifactNotFound,
				RequestID:     "request:other",
				SchemaVersion: workercontracts.RadarrRepairWorkerV1,
				Status:        workercontracts.Failed,
			},
		})
	}))
	client := testClient(t, socketPath, testRoots(), time.Second)

	_, err := client.PublishJoin(context.Background(), Artifact{
		ID: testArtifactID, Fingerprint: testArtifactFingerprint,
	})
	assertFailure(t, err, FailureInvalidResponse, "")
}

func authorizedJoin() (decisionpolicy.AuthorizedJoin, map[controller.FileID]string) {
	firstID := controller.FileID("file:part:01")
	secondID := controller.FileID("file:part:02")
	firstFingerprint := controller.FileFingerprint{
		Device: 1, Inode: 2, SizeBytes: 10, MTimeNS: 3,
	}
	secondFingerprint := controller.FileFingerprint{
		Device: 1, Inode: 4, SizeBytes: 20, MTimeNS: 5,
	}
	authorized := decisionpolicy.AuthorizedJoin{
		CaseID:       "sha256:1111111111111111111111111111111111111111111111111111111111111111",
		CapabilityID: "capability:join:01",
		OrderedParts: []decisionpolicy.AuthorizedJoinPart{
			{FileID: firstID, Fingerprint: firstFingerprint},
			{FileID: secondID, Fingerprint: secondFingerprint},
		},
		SourceBytes:         30,
		ExpectedDurationMS:  2_000,
		DurationToleranceMS: 100,
		OutputContainer:     controller.OutputContainerMKV,
		ExpectedStreamLayout: controller.StreamLayout{
			Streams: []controller.StreamLayoutEntry{{Kind: controller.ProbeStreamVideo}},
		},
	}
	paths := map[controller.FileID]string{
		firstID:  "/downloads/Movie.Release/CD1.mkv",
		secondID: "/downloads/Movie.Release/CD2.mkv",
	}
	return authorized, paths
}

func readStageJoinRequest(
	request *http.Request,
) (workercontracts.StageJoinRequestV1, error) {
	data, err := readJoinRequest(request, stageJoinPath)
	if err != nil {
		return workercontracts.StageJoinRequestV1{}, err
	}
	return workercontracts.DecodeStageJoinRequest(data)
}

func readPublishRequest(request *http.Request) (workercontracts.PublishRequestV1, error) {
	data, err := readJoinRequest(request, publishPath)
	if err != nil {
		return workercontracts.PublishRequestV1{}, err
	}
	return workercontracts.DecodePublishRequest(data)
}

func readDiscardRequest(request *http.Request) (workercontracts.DiscardRequestV1, error) {
	data, err := readJoinRequest(request, discardPath)
	if err != nil {
		return workercontracts.DiscardRequestV1{}, err
	}
	return workercontracts.DecodeDiscardRequest(data)
}

func readInspectJoinRequest(
	request *http.Request,
) (workercontracts.InspectJoinRequestV1, error) {
	data, err := readJoinRequest(request, inspectPath)
	if err != nil {
		return workercontracts.InspectJoinRequestV1{}, err
	}
	return workercontracts.DecodeInspectJoinRequest(data)
}

func readJoinRequest(request *http.Request, path string) ([]byte, error) {
	if request.Method != http.MethodPost || request.URL.Path != path ||
		request.Header.Get("Content-Type") != "application/json" {
		return nil, fmt.Errorf("unexpected request")
	}
	return io.ReadAll(request.Body)
}

func writeStageJoinResponse(
	writer http.ResponseWriter,
	response workercontracts.StageJoinResponseV1,
) {
	data, err := workercontracts.EncodeStageJoinResponse(response)
	writeJoinResponse(writer, data, err)
}

func writePublishResponse(
	writer http.ResponseWriter,
	response workercontracts.PublishResponseV1,
) {
	data, err := workercontracts.EncodePublishResponse(response)
	writeJoinResponse(writer, data, err)
}

func writeDiscardResponse(
	writer http.ResponseWriter,
	response workercontracts.DiscardResponseV1,
) {
	data, err := workercontracts.EncodeDiscardResponse(response)
	writeJoinResponse(writer, data, err)
}

func writeInspectJoinResponse(
	writer http.ResponseWriter,
	response workercontracts.InspectJoinResponseV1,
) {
	data, err := workercontracts.EncodeInspectJoinResponse(response)
	writeJoinResponse(writer, data, err)
}

func writeJoinResponse(writer http.ResponseWriter, data []byte, err error) {
	if err != nil {
		writer.WriteHeader(http.StatusInternalServerError)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	_, _ = writer.Write(data)
}

package workerclient

import (
	"context"
	"io"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

func TestClientIdentifiesBluRayPlaylistThroughWorker(t *testing.T) {
	t.Parallel()
	requests := make(chan workercontracts.BlurayIdentifyRequestV1, 1)
	socketPath := serveUnix(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Error(err)
			return
		}
		identified, err := workercontracts.DecodeBlurayIdentifyRequest(body)
		if err != nil {
			t.Error(err)
			return
		}
		requests <- identified
		response := workercontracts.BlurayIdentifyResponseV1{
			Kind: workercontracts.ProbeResponseSucceeded,
			Success: &workercontracts.BlurayIdentifySuccessV1{
				SchemaVersion: workercontracts.RadarrRepairWorkerV1,
				Operation:     workercontracts.IdentifyBlurayV1,
				RequestID:     identified.RequestID, Status: workercontracts.Ok,
				DurationMS: 5_629_498, ChapterCount: 5,
				ClipNames: []string{"00000.m2ts"},
				Tracks:    []workercontracts.Track{{Kind: "video", Codec: "AVC", Language: nil}},
			},
		}
		data, err := workercontracts.EncodeBlurayIdentifyResponse(response)
		if err != nil {
			t.Error(err)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write(data)
	}))
	client := testClient(t, socketPath, map[string]string{"root:downloads": "/downloads"}, time.Second)
	target := mkvmerge.Target{
		Path:                "/downloads/Movie/BDMV/PLAYLIST/00000.mpls",
		ExpectedFingerprint: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
	}
	playlist, err := client.Identify(context.Background(), target)
	if err != nil {
		t.Fatal(err)
	}
	if playlist.DurationMS != 5_629_498 || playlist.Chapters != 5 ||
		!reflect.DeepEqual(playlist.ClipPaths, []string{
			"/downloads/Movie/BDMV/STREAM/00000.m2ts",
		}) || len(playlist.Tracks) != 1 || playlist.Tracks[0].Kind != "video" {
		t.Fatalf("playlist = %#v", playlist)
	}
	request := <-requests
	if request.RootID != "root:downloads" ||
		!reflect.DeepEqual(request.PathComponents, []string{
			"Movie", "BDMV", "PLAYLIST", "00000.mpls",
		}) || request.ExpectedFingerprint != target.ExpectedFingerprint {
		t.Fatalf("worker request = %#v", request)
	}
}

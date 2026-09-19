package workerclient

import (
	"context"
	"io"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/mkvmerge"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/mediaevidence"
)

func TestClientStagesAuthorizedBluRayThroughUnixSocket(t *testing.T) {
	t.Parallel()
	requests := make(chan workercontracts.BlurayRemuxRequestV1, 1)
	socketPath := serveUnix(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != blurayRemuxPath {
			http.NotFound(writer, request)
			return
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Error(err)
			return
		}
		staged, err := workercontracts.DecodeBlurayRemuxRequest(body)
		if err != nil {
			t.Error(err)
			return
		}
		requests <- staged
		evidence := completeEvidence()
		response := workercontracts.BlurayRemuxResponseV1{
			Kind: workercontracts.ProbeResponseSucceeded,
			Success: &workercontracts.BlurayRemuxSuccessV1{
				SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
				Operation:           workercontracts.StageBlurayRemuxV1,
				RequestID:           staged.RequestID,
				Status:              workercontracts.Ok,
				ArtifactID:          "artifact:remux:01",
				ArtifactFingerprint: testArtifactFingerprint,
				SizeBytes:           8_390_000_000,
				Evidence:            mediaevidence.FromProbe(evidence),
			},
		}
		data, err := workercontracts.EncodeBlurayRemuxResponse(response)
		if err != nil {
			t.Error(err)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write(data)
	}))
	client := testClient(t, socketPath, map[string]string{
		"root:downloads": "/downloads",
	}, time.Second)
	playlist := decisionpolicy.AuthorizedRemuxFile{
		FileID: "playlist", Fingerprint: controller.FileFingerprint{
			Device: 1, Inode: 2, SizeBytes: 4096, MTimeNS: 3,
		},
	}
	clip := decisionpolicy.AuthorizedRemuxFile{
		FileID: "clip", Fingerprint: controller.FileFingerprint{
			Device: 1, Inode: 4, SizeBytes: 8_390_000_000, MTimeNS: 3,
		},
	}
	authorized := decisionpolicy.AuthorizedRemux{
		CaseID:       "sha256:3333333333333333333333333333333333333333333333333333333333333333",
		CapabilityID: "capability:remux:01",
		Playlist:     playlist, Clips: []decisionpolicy.AuthorizedRemuxFile{clip},
		ExpectedDurationMS: 7_200_000, ExpectedChapters: 0,
		ExpectedTracks: []mkvmerge.Track{{Kind: "video", Codec: "AVC", Language: ""}},
	}
	paths := map[controller.FileID]string{
		"playlist": "/downloads/Movie/BDMV/PLAYLIST/00000.mpls",
		"clip":     "/downloads/Movie/BDMV/STREAM/00000.m2ts",
	}
	exchange, err := client.StageBlurayRemux(
		context.Background(), "execution:remux:01", authorized, paths,
	)
	if err != nil || exchange.Response.Success == nil ||
		exchange.Response.Success.ArtifactID != "artifact:remux:01" {
		t.Fatalf("stage exchange = %#v, error = %v", exchange, err)
	}
	request := <-requests
	if request.RootID != "root:downloads" ||
		!reflect.DeepEqual(request.Playlist.PathComponents, []string{
			"Movie", "BDMV", "PLAYLIST", "00000.mpls",
		}) || len(request.Clips) != 1 ||
		!reflect.DeepEqual(request.Clips[0].PathComponents, []string{
			"Movie", "BDMV", "STREAM", "00000.m2ts",
		}) || request.Clips[0].ExpectedFingerprint != clip.Fingerprint.Fingerprint() ||
		request.ExpectedDurationMS != authorized.ExpectedDurationMS ||
		request.ExpectedTracks[0].Kind != "video" {
		t.Fatalf("worker remux request = %#v", request)
	}
}

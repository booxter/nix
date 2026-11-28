package workerclient

import (
	"context"
	"io"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

func TestClientPreservesDVDOverlapEvidence(t *testing.T) {
	t.Parallel()
	handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Error(err)
			return
		}
		identified, err := workercontracts.DecodeDVDIdentifyRequest(body)
		if err != nil {
			t.Error(err)
			return
		}
		first := workercontracts.DVDTitleV1{
			Number: 1, DurationMS: 83_880, ChapterCount: 3, AngleCount: 1, TitleSet: 1, TitleInSet: 1,
			Tracks: []workercontracts.DVDTrackV1{{Kind: "video", Codec: "mpeg2video"}},
			Overlaps: []workercontracts.DVDOverlapV1{{Title: 2, SharedDurationMS: 66_720,
				Ranges: []workercontracts.DVDOverlapRangeV1{
					{StartMS: 0, OtherStartMS: 0, DurationMS: 6_720},
					{StartMS: 23_880, OtherStartMS: 6_720, DurationMS: 60_000},
				},
			}},
		}
		second := first
		second.Number, second.TitleInSet, second.Overlaps = 2, 2, nil
		response := workercontracts.DVDIdentifyResponseV1{
			Kind: workercontracts.ProbeResponseSucceeded,
			Success: &workercontracts.DVDIdentifySuccessV1{
				SchemaVersion: workercontracts.RadarrRepairWorkerV1, Operation: workercontracts.IdentifyDVDV1,
				RequestID: identified.RequestID, Status: workercontracts.Ok,
				Titles: []workercontracts.DVDTitleV1{first, second},
			},
		}
		data, err := workercontracts.EncodeDVDIdentifyResponse(response)
		if err != nil {
			t.Error(err)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write(data)
	})
	client := testClient(t, handler, map[string]string{"root:downloads": "/downloads"}, time.Second)
	titles, err := client.IdentifyDVD(context.Background(), dvdvideo.Target{
		NavigationPath:      "/downloads/Movie/VIDEO_TS.IFO",
		ExpectedFingerprint: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
	})
	want := []dvdvideo.Overlap{{Title: 2, SharedDurationMS: 66_720, Ranges: []dvdvideo.OverlapRange{
		{StartMS: 0, OtherStartMS: 0, DurationMS: 6_720},
		{StartMS: 23_880, OtherStartMS: 6_720, DurationMS: 60_000},
	}}}
	if err != nil || len(titles) != 2 || !reflect.DeepEqual(titles[0].Overlaps, want) {
		t.Fatalf("DVD overlap evidence: %+v, %v", titles, err)
	}
}

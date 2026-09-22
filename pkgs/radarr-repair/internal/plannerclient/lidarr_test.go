package plannerclient

import (
	"context"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/lidarrcontracts"
)

func TestClientPlansLidarrCaseThroughSharedTransport(t *testing.T) {
	t.Parallel()
	repairCase := plannerLidarrCase(t)
	want := lidarrcontracts.Decision{Kind: lidarrcontracts.ActionNoRepair}
	want.NoRepair = &lidarrcontracts.NoRepairDecision{
		SchemaVersion: lidarrcontracts.SchemaVersion, CaseID: repairCase.CaseID,
		Action: string(lidarrcontracts.ActionNoRepair), Reason: "unsupported_repair",
		EvidenceRefs: []string{}, Explanation: "No supported repair applies.",
	}
	response, err := lidarrcontracts.EncodeDecision(want)
	if err != nil {
		t.Fatal(err)
	}
	socketPath := serveUnix(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/lidarr/v1/repair-plans" {
			http.NotFound(writer, request)
			return
		}
		writeJSON(writer, response)
	}))
	client := testClient(t, socketPath, time.Second)

	actual, err := client.PlanLidarr(context.Background(), repairCase)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actual, want) {
		t.Fatalf("decision = %#v, want %#v", actual, want)
	}
}

func plannerLidarrCase(t *testing.T) lidarrcontracts.Case {
	t.Helper()
	duration := int64(1000)
	repairCase := lidarrcontracts.Case{
		SchemaVersion: lidarrcontracts.SchemaVersion,
		ObservedAt:    time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC),
		Queue: lidarrcontracts.Queue{
			QueueID: 1, Title: "Artist - Album", DownloadRef: "download:one", Messages: []string{},
		},
		Album: lidarrcontracts.Album{
			AlbumID: 3, ArtistID: 2, Artist: "Artist", Title: "Album", Monitored: true,
		},
		Releases: []lidarrcontracts.Release{{
			ReleaseID: 4, Title: "Album", TrackCount: 1, MediumCount: 1, Monitored: true,
		}},
		Tracks: []lidarrcontracts.Track{{
			TrackID: 5, Number: "1", AbsoluteNumber: 1, MediumNumber: 1,
			Title: "Track", DurationMS: 1000,
		}},
		Artifacts: []lidarrcontracts.Artifact{{
			ArtifactID: "artifact:one", RelativePath: "01.flac",
			Fingerprint: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			SizeBytes:   100, DurationMS: &duration, Formats: []string{"flac"},
			Tags: []lidarrcontracts.Tag{}, Streams: []lidarrcontracts.Stream{},
		}},
		Assessments: []lidarrcontracts.Assessment{},
		Capabilities: []lidarrcontracts.Capability{{
			Action: string(lidarrcontracts.ActionImportTrackSet), CapabilityID: "capability:one",
			AlbumID: 3, ArtifactIDs: []string{"artifact:one"},
			ReleaseIDs: []int64{4}, TrackIDs: []int64{5},
		}},
	}
	caseID, err := lidarrcontracts.CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	repairCase.CaseID = caseID
	return repairCase
}

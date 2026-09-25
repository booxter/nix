package lidarrreview

import (
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/review"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

func TestSnapshotShowsPlannerExplanation(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 25, 2, 0, 0, 0, time.UTC)
	duration := int64(1000)
	codec := "flac"
	repairCase := lidarrcontracts.Case{
		SchemaVersion: lidarrcontracts.SchemaVersion, ObservedAt: now,
		Queue: lidarrcontracts.Queue{
			QueueID: 9, Title: "Release", DownloadRef: "download:one", Messages: []string{},
		},
		Album: lidarrcontracts.Album{AlbumID: 3, ArtistID: 4, Artist: "Artist", Title: "Album", Monitored: true},
		Releases: []lidarrcontracts.Release{{
			ReleaseID: 6, ForeignReleaseID: "release", Title: "Album", Format: "Album",
			Countries: []string{}, Labels: []string{}, TrackCount: 1, MediumCount: 1, Monitored: true,
		}},
		Tracks: []lidarrcontracts.Track{{
			TrackID: 7, ReleaseID: 6, Number: "1", AbsoluteNumber: 1, MediumNumber: 1,
			Title: "Track", DurationMS: 1000,
		}},
		Artifacts: []lidarrcontracts.Artifact{{
			ArtifactID: "artifact:one", RelativePath: "01.flac",
			Fingerprint: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			SizeBytes:   100, DurationMS: &duration, Formats: []string{"flac"},
			Tags: []lidarrcontracts.Tag{}, Streams: []lidarrcontracts.Stream{{Kind: "audio", Codec: &codec}},
		}},
		Assessments: []lidarrcontracts.Assessment{{
			ArtifactID: "artifact:one", TrackIDs: []int64{}, TagTrackNumbers: []int{},
			Rejections: []string{"missing track"},
		}},
		Capabilities: []lidarrcontracts.Capability{},
	}
	caseID, err := lidarrcontracts.CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	repairCase.CaseID = caseID
	caseData, err := lidarrcontracts.EncodeCase(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	decisionData, err := lidarrcontracts.EncodeDecision(lidarrcontracts.Decision{
		Kind: lidarrcontracts.ActionNoRepair,
		NoRepair: &lidarrcontracts.NoRepairDecision{
			SchemaVersion: lidarrcontracts.SchemaVersion, CaseID: caseID,
			Action: string(lidarrcontracts.ActionNoRepair), Reason: "incomplete_release",
			EvidenceRefs: []string{"artifact:one"}, Explanation: "One expected track is absent.",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := Snapshot(lidarrrepair.Report{Reviews: []lidarrrepair.QueueReview{{
		Queue: lidarr.QueueRecord{
			ID: 9, Title: "Release", Status: "completed", TrackedDownloadStatus: "warning",
		},
		Candidate: true, Outcome: planningrunner.Decided,
		Record: lidarrrepair.Record{
			QueueID: 9, SourceFingerprint: caseID, Case: caseData, Decision: decisionData,
		},
	}}}, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Current) != 1 || snapshot.Current[0].State != review.StateReviewed ||
		snapshot.Current[0].Decision == nil ||
		snapshot.Current[0].Decision.Explanation != "One expected track is absent." ||
		snapshot.Current[0].Subject != "Artist — Album" {
		t.Fatalf("snapshot = %#v", snapshot)
	}
}

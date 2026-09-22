package lidarrcontracts

import (
	"strings"
	"testing"
	"time"
)

func TestCaseRoundTrip(t *testing.T) {
	repairCase := testCase(t)
	encoded, err := EncodeCase(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeCase(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.CaseID != repairCase.CaseID || decoded.Artifacts[0].ArtifactID != "artifact:one" {
		t.Fatalf("unexpected decoded case: %#v", decoded)
	}
}

func TestCaseIDIgnoresObservationTime(t *testing.T) {
	first := testCase(t)
	second := first
	second.ObservedAt = first.ObservedAt.Add(time.Hour)
	actual, err := CalculateCaseID(second)
	if err != nil {
		t.Fatal(err)
	}
	if actual != first.CaseID {
		t.Fatalf("case ID changed with observation time: %s != %s", actual, first.CaseID)
	}
}

func TestDecodeCaseRejectsIdentityMismatch(t *testing.T) {
	repairCase := testCase(t)
	encoded, err := EncodeCase(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	tampered := strings.Replace(string(encoded), "An Album", "Other Album", 1)
	if _, err := DecodeCase([]byte(tampered)); err == nil || !strings.Contains(err.Error(), "case ID") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDecisionRoundTrip(t *testing.T) {
	repairCase := testCase(t)
	decision := Decision{
		Kind: ActionImportTrackSet,
		ImportTrackSet: &ImportTrackSetDecision{
			SchemaVersion: SchemaVersion, CaseID: repairCase.CaseID,
			Action: string(ActionImportTrackSet), CapabilityID: "capability:one",
			AlbumID: 3, ReleaseID: 4,
			Mappings:     []TrackMapping{{ArtifactID: "artifact:one", TrackID: 5}},
			EvidenceRefs: []string{"artifact:one"}, Explanation: "The tags and duration agree.",
		},
	}
	encoded, err := EncodeDecision(decision)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeDecision(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.CaseID() != repairCase.CaseID || decoded.ImportTrackSet.ReleaseID != 4 {
		t.Fatalf("unexpected decoded decision: %#v", decoded)
	}
}

func testCase(t *testing.T) Case {
	t.Helper()
	codec := "flac"
	duration := int64(180000)
	sampleRate := int64(44100)
	channels := int64(2)
	repairCase := Case{
		SchemaVersion: SchemaVersion,
		ObservedAt:    time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC),
		Queue: Queue{
			QueueID: 1, Title: "Artist - An Album", DownloadRef: "download:one",
			Messages: []string{"Found archive file, might need to be extracted"},
		},
		Album: Album{AlbumID: 3, ArtistID: 2, Artist: "Artist", Title: "An Album", Monitored: true},
		Releases: []Release{{
			ReleaseID: 4, Title: "An Album", Disambiguation: "", Format: "Album",
			TrackCount: 1, MediumCount: 1, Monitored: true,
		}},
		Tracks: []Track{{
			TrackID: 5, Number: "1", AbsoluteNumber: 1, MediumNumber: 1,
			Title: "A Track", DurationMS: 180000, HasFile: false,
		}},
		Artifacts: []Artifact{{
			ArtifactID: "artifact:one", RelativePath: "01 - A Track.flac",
			Fingerprint: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			SizeBytes:   1000, DurationMS: &duration, Formats: []string{"flac"},
			Tags: []Tag{{Name: "title", Value: "A Track"}},
			Streams: []Stream{{
				Kind: "audio", Codec: &codec, SampleRateHz: &sampleRate, Channels: &channels,
			}},
		}},
		Assessments: []Assessment{{
			ArtifactID: "artifact:one", AlbumID: int64Pointer(3), ReleaseID: int64Pointer(4),
			TrackIDs: []int64{5}, TagTitle: stringPointer("A Track"),
			TagArtist: stringPointer("Artist"), TagAlbum: stringPointer("An Album"),
			TagTrackNumbers: []int{1}, Rejections: []string{},
		}},
		Capabilities: []Capability{{
			Action: string(ActionImportTrackSet), CapabilityID: "capability:one", AlbumID: 3,
			ArtifactIDs: []string{"artifact:one"}, ReleaseIDs: []int64{4}, TrackIDs: []int64{5},
		}},
	}
	caseID, err := CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	repairCase.CaseID = caseID
	return repairCase
}

func int64Pointer(value int64) *int64    { return &value }
func stringPointer(value string) *string { return &value }

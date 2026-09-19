package casestore

import (
	"reflect"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/radarr-repair/internal/repairartifact"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

func TestDVDExecutionBindsStagedAndPublishedArtifact(t *testing.T) {
	t.Parallel()
	caseID := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	file := func(id controller.FileID, inode uint64) decisionpolicy.AuthorizedRemuxFile {
		return decisionpolicy.AuthorizedRemuxFile{
			FileID: id,
			Fingerprint: controller.FileFingerprint{
				Device: 1, Inode: inode, SizeBytes: 1024, MTimeNS: 3,
			},
		}
	}
	navigation := file("file:navigation", 1)
	sources := []decisionpolicy.AuthorizedRemuxFile{
		navigation, file("file:backup", 2), file("file:movie", 3),
	}
	authorized := decisionpolicy.AuthorizedDVD{
		CaseID: caseID, CapabilityID: "capability:dvd", Navigation: navigation,
		Sources: sources, SourceBytes: 3072, TitleNumber: 1,
		ExpectedDurationMS: 7_200_000, ExpectedChapters: 12,
		ExpectedTracks: []dvdvideo.Track{{Kind: "video", Codec: "mpeg2video"}},
	}
	id, err := DVDExecutionID(authorized)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)
	prepared := RemuxExecution{
		Version: DVDExecutionVersionV1, ExecutionID: id,
		DVDAuthorization: &authorized, State: RemuxPrepared,
		PreparedAt: now, UpdatedAt: now,
	}
	assertDVDExecutionRoundTrip(t, prepared)
	source := func(file decisionpolicy.AuthorizedRemuxFile, name string) workercontracts.DVDRemuxSourceV1 {
		return workercontracts.DVDRemuxSourceV1{
			PathComponents:      []string{"Movie", "VIDEO_TS", name},
			ExpectedFingerprint: file.Fingerprint.Fingerprint(),
			SizeBytes:           file.Fingerprint.SizeBytes,
		}
	}
	request := workercontracts.DVDRemuxRequestV1{
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
		Operation:     workercontracts.StageDVDRemuxV1,
		RequestID:     "request:dvd", ExecutionID: id, CaseID: caseID,
		CapabilityID: authorized.CapabilityID, RootID: "downloads",
		Navigation: source(navigation, "VIDEO_TS.IFO"),
		Sources: []workercontracts.DVDRemuxSourceV1{
			source(sources[0], "VIDEO_TS.IFO"), source(sources[1], "VIDEO_TS.BUP"),
			source(sources[2], "VTS_01_1.VOB"),
		},
		TitleNumber: 1, ExpectedDurationMS: authorized.ExpectedDurationMS,
		ExpectedChapterCount: int64(authorized.ExpectedChapters),
		ExpectedTracks: []workercontracts.DVDRemuxTrackV1{{
			Kind: workercontracts.TrackKind("video"), Codec: "mpeg2video", Language: "",
		}},
	}
	artifact := &RemuxArtifact{
		ID: "artifact:dvd", Fingerprint: navigation.Fingerprint.Fingerprint(), SizeBytes: 2048,
	}
	staged := prepared
	staged.State = RemuxStaged
	staged.UpdatedAt = now.Add(time.Minute)
	staged.DVDStageRequest = &request
	staged.Artifact = artifact
	assertDVDExecutionRoundTrip(t, staged)
	published := staged
	published.State = RemuxPublished
	published.UpdatedAt = now.Add(2 * time.Minute)
	published.Published = &RemuxPublishedArtifact{
		RootID:         "downloads",
		PathComponents: []string{"Movie", repairartifact.PublishedName(artifact.ID, ".mkv")},
	}
	assertDVDExecutionRoundTrip(t, published)

	wrong := published
	wrong.Published = &RemuxPublishedArtifact{
		RootID: "downloads", PathComponents: []string{"Other", published.Published.PathComponents[1]},
	}
	if _, err := EncodeRemuxExecution(wrong); err == nil {
		t.Fatal("accepted publication outside the DVD directory")
	}
	wrong = published
	badRequest := request
	badRequest.TitleNumber = 2
	wrong.DVDStageRequest = &badRequest
	if _, err := EncodeRemuxExecution(wrong); err == nil {
		t.Fatal("accepted a different DVD title")
	}
}

func assertDVDExecutionRoundTrip(t *testing.T, record RemuxExecution) {
	t.Helper()
	data, err := EncodeRemuxExecution(record)
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeRemuxExecution(data)
	if err != nil || !reflect.DeepEqual(got, record) {
		t.Fatalf("roundtrip state %q: record = %#v, error = %v", record.State, got, err)
	}
}

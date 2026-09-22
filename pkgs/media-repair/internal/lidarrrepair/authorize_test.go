package lidarrrepair

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
	"golift.io/starr"
)

func TestAuthorizeImportControlsReleaseSwitchingFromCurrentLibrary(t *testing.T) {
	t.Parallel()
	for _, albumHasFiles := range []bool{false, true} {
		albumHasFiles := albumHasFiles
		t.Run(map[bool]string{false: "empty album", true: "partial album"}[albumHasFiles], func(t *testing.T) {
			t.Parallel()
			planned, current := testPlannedImport(t, albumHasFiles)
			authorized, found, err := AuthorizeImport(planned, current)
			if err != nil || !found {
				t.Fatalf("found = %v, error = %v", found, err)
			}
			if len(authorized.Tracks) != 1 || authorized.Tracks[0].TrackID != 11 ||
				authorized.Tracks[0].DisableReleaseSwitching != albumHasFiles {
				t.Fatalf("authorization = %#v", authorized)
			}
		})
	}
}

func TestAuthorizeImportRejectsChangedBinding(t *testing.T) {
	t.Parallel()
	planned, current := testPlannedImport(t, false)
	current.Bindings[0].Path = "/downloads/staged/replaced.flac"
	if _, _, err := AuthorizeImport(planned, current); err == nil {
		t.Fatal("changed current binding was accepted")
	}
}

func TestAuthorizeImportRevalidatesRecoveredWorkspaceAgainstCurrentCapabilities(t *testing.T) {
	t.Parallel()
	planned, current := testPlannedImport(t, false)
	plannedCase, err := lidarrcontracts.DecodeCase(planned.Case)
	if err != nil {
		t.Fatal(err)
	}
	current.Recovered = true
	current.Case.CaseID = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

	authorized, found, err := AuthorizeImport(planned, current)
	if err != nil || !found || authorized.CaseID != plannedCase.CaseID {
		t.Fatalf("authorization = %#v, found = %v, error = %v", authorized, found, err)
	}
	current.Case.Capabilities = nil
	if _, _, err := AuthorizeImport(planned, current); err == nil {
		t.Fatal("recovered workspace without a current capability was accepted")
	}
}

func TestStorePersistsImportExecutionTransitions(t *testing.T) {
	t.Parallel()
	planned, current := testPlannedImport(t, false)
	store, err := NewStore(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(planned); err != nil {
		t.Fatal(err)
	}
	authorized, found, err := AuthorizeImport(planned, current)
	if err != nil || !found {
		t.Fatalf("found = %v, error = %v", found, err)
	}
	now := time.Date(2026, 9, 22, 13, 0, 0, 0, time.UTC)
	execution, prepared, err := store.PrepareImport(authorized, 90, now)
	if err != nil || !prepared || execution.State != ImportPrepared {
		t.Fatalf("execution = %#v, prepared = %v, error = %v", execution, prepared, err)
	}
	execution, changed, err := store.MarkImportRequested(1, 81, now)
	if err != nil || !changed || execution.State != ImportRequested {
		t.Fatalf("execution = %#v, changed = %v, error = %v", execution, changed, err)
	}
	execution, changed, err = store.MarkImported(1, []lidarr.ImportedTrack{{
		HistoryID: 91, AlbumID: 3, ArtistID: 2, TrackID: 11, DownloadID: "download",
		DroppedPath: "/downloads/staged/02.flac", ImportedPath: "/music/02.flac",
		OccurredAt: now,
	}}, now)
	if err != nil || !changed || execution.State != Imported {
		t.Fatalf("execution = %#v, changed = %v, error = %v", execution, changed, err)
	}
	stored, found, err := store.GetImportExecution(1)
	if err != nil || !found || stored.State != Imported || len(stored.Confirmations) != 1 {
		t.Fatalf("stored = %#v, found = %v, error = %v", stored, found, err)
	}
}

func testPlannedImport(t *testing.T, albumHasFiles bool) (Record, Evidence) {
	t.Helper()
	tracks := []lidarrcontracts.Track{{
		TrackID: 11, ReleaseID: 7, Number: "2", AbsoluteNumber: 2,
		MediumNumber: 1, Title: "Missing", DurationMS: 1000,
	}}
	trackCount := 1
	if albumHasFiles {
		tracks = append([]lidarrcontracts.Track{{
			TrackID: 10, ReleaseID: 7, Number: "1", AbsoluteNumber: 1,
			MediumNumber: 1, Title: "Existing", DurationMS: 1000, HasFile: true,
		}}, tracks...)
		trackCount = 2
	}
	repairCase := lidarrcontracts.Case{
		SchemaVersion: lidarrcontracts.SchemaVersion,
		ObservedAt:    time.Date(2026, 9, 22, 12, 0, 0, 0, time.UTC),
		Queue: lidarrcontracts.Queue{
			QueueID: 1, Title: "Artist - Album", DownloadRef: "download:opaque", Messages: []string{},
		},
		Album: lidarrcontracts.Album{
			AlbumID: 3, ArtistID: 2, Artist: "Artist", Title: "Album", Monitored: true,
		},
		Releases: []lidarrcontracts.Release{{
			ReleaseID: 7, ForeignReleaseID: "release", Title: "Album", Format: "Vinyl",
			Countries: []string{"DE"}, Labels: []string{"Label"}, TrackCount: trackCount,
			MediumCount: 1, Monitored: true,
		}},
		Tracks: tracks,
		Artifacts: []lidarrcontracts.Artifact{{
			ArtifactID: "artifact:one", RelativePath: "02.flac",
			Fingerprint: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			SizeBytes:   100, DurationMS: pointer(int64(1000)), Formats: []string{"flac"},
			Tags: []lidarrcontracts.Tag{}, Streams: []lidarrcontracts.Stream{},
		}},
		Assessments: []lidarrcontracts.Assessment{{
			ArtifactID: "artifact:one", TrackIDs: []int64{}, TagTrackNumbers: []int{},
			Rejections: []string{},
		}},
		Capabilities: []lidarrcontracts.Capability{{
			Action:       string(lidarrcontracts.ActionImportMissingTracks),
			CapabilityID: "capability:import_missing_tracks:7", AlbumID: 3,
			ArtifactIDs: []string{"artifact:one"}, ReleaseID: 7, TrackIDs: []int64{11},
		}},
	}
	caseID, err := lidarrcontracts.CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	repairCase.CaseID = caseID
	decision := lidarrcontracts.Decision{
		Kind: lidarrcontracts.ActionImportMissingTracks,
		ImportMissingTracks: &lidarrcontracts.ImportMissingTracksDecision{
			SchemaVersion: lidarrcontracts.SchemaVersion, CaseID: caseID,
			Action:       string(lidarrcontracts.ActionImportMissingTracks),
			CapabilityID: "capability:import_missing_tracks:7", AlbumID: 3, ReleaseID: 7,
			Mappings:     []lidarrcontracts.TrackMapping{{ArtifactID: "artifact:one", TrackID: 11}},
			EvidenceRefs: []string{"artifact:one"}, Explanation: "The tags and order match.",
		},
	}
	caseData, err := lidarrcontracts.EncodeCase(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	decisionData, err := lidarrcontracts.EncodeDecision(decision)
	if err != nil {
		t.Fatal(err)
	}
	quality := &starr.Quality{Quality: &starr.BaseQuality{ID: 6, Name: "FLAC"}}
	bindings := []ImportBinding{{
		ArtifactID: "artifact:one", Path: "/downloads/staged/02.flac",
		Quality: quality, DownloadID: "download",
	}}
	return Record{
			Version: stateVersion, QueueID: 1, ArchivePath: "/downloads/album.tar",
			ArchiveFingerprint: "1:2:3:4", WorkspaceRoot: "/downloads/staged",
			Case: caseData, Decision: decisionData, Bindings: bindings,
		}, Evidence{
			Queue: lidarr.QueueRecord{
				ID: 1, DownloadID: "download", AlbumID: pointer(int64(3)), ArtistID: pointer(int64(2)),
			},
			ArchivePath: "/downloads/album.tar", ArchiveFingerprint: "1:2:3:4",
			WorkspaceRoot: "/downloads/staged", Case: repairCase,
			Bindings: append([]ImportBinding(nil), bindings...),
		}
}

package lidarrrepair

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

type fakeLidarr struct {
	queue             []lidarr.QueueRecord
	imports           []lidarr.ManualImport
	recoveredIdentity lidarr.AlbumIdentity
	recoveredFound    bool
	identityReads     int
}

func (fake *fakeLidarr) ReadQueue(context.Context) ([]lidarr.QueueRecord, error) {
	return fake.queue, nil
}

func (fake *fakeLidarr) RecoverAlbumIdentity(
	context.Context,
	string,
) (lidarr.AlbumIdentity, bool, error) {
	fake.identityReads++
	return fake.recoveredIdentity, fake.recoveredFound, nil
}

func (fake *fakeLidarr) ReadAlbum(context.Context, int64) (lidarr.Album, error) {
	return lidarr.Album{
		ID: 3, ArtistID: 2, ArtistName: "Artist", Title: "Album", Monitored: true,
		Releases: []lidarr.Release{{
			ID: 4, ForeignReleaseID: "release", Title: "Album", Format: "Album", TrackCount: 1,
			MediumCount: 1, Monitored: true,
		}},
	}, nil
}

func (fake *fakeLidarr) ReadReleaseTracks(
	_ context.Context,
	albumID int64,
	releaseID int64,
) ([]lidarr.Track, error) {
	if albumID != 3 || releaseID != 4 {
		panic("unexpected release-track query")
	}
	return []lidarr.Track{{
		ID: 5, AlbumID: 3, ReleaseID: 4, ArtistID: 2, AbsoluteTrackNumber: 1,
		TrackNumber: "1", MediumNumber: 1, Title: "Track", DurationMS: 1000,
	}}, nil
}

func (fake *fakeLidarr) ReadManualImports(
	_ context.Context,
	query lidarr.ManualImportQuery,
) ([]lidarr.ManualImport, error) {
	if query.Folder != "/downloads/.media-repair/workspaces/workspace:test" || query.ArtistID != 2 {
		panic("unexpected manual-import workspace")
	}
	return fake.imports, nil
}

type fakeWorker struct {
	calls           int
	directoryCalls  int
	directoryAudio  bool
	tarWorkspaceIDs []string
}

func (fake *fakeWorker) MaterializeTarAudio(
	_ context.Context,
	_ string,
	snapshot fileidentity.Snapshot,
	workspaceID string,
) (materialize.Success, error) {
	fake.calls++
	fake.tarWorkspaceIDs = append(fake.tarWorkspaceIDs, workspaceID)
	return testMaterialization(materialize.OperationMaterializeTar, snapshot.StableFingerprint()), nil
}

func testMaterialization(operation, sourceFingerprint string) materialize.Success {
	duration := int64(1000)
	kind := workercontracts.FluffyAudio
	codec := "flac"
	return materialize.Success{
		SchemaVersion: materialize.SchemaVersion, RequestID: "request:test",
		Operation: operation, RootID: "usenet",
		SourceFingerprint:   sourceFingerprint,
		WorkspaceComponents: []string{".media-repair", "workspaces", "workspace:test"},
		Artifacts: []materialize.Artifact{{
			ArtifactID: "artifact:one",
			PathComponents: []string{
				".media-repair", "workspaces", "workspace:test", "01.flac",
			},
			RelativePath: "01.flac", SizeBytes: 100,
			Fingerprint: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			Evidence: workercontracts.Evidence{
				Format: workercontracts.Format{
					Names: []string{"flac"}, DurationMS: &duration, SizeBytes: pointer(int64(100)),
				},
				Streams: []workercontracts.StreamElement{{
					Index: 0, Kind: &kind, CodecName: &codec, DurationMS: &duration,
				}},
				Programs: []workercontracts.ProgramElement{},
				Chapters: []workercontracts.ChapterElement{},
			},
		}},
	}
}

func (fake *fakeWorker) MaterializeDirectoryAudio(
	context.Context,
	string,
	string,
) (materialize.Success, error) {
	fake.directoryCalls++
	if fake.directoryAudio {
		return testMaterialization(
			materialize.OperationMaterializeDirectory,
			"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		), nil
	}
	return materialize.Success{}, &materialize.Rejection{Reason: materialize.FailureNoSupportedAudio}
}

func (fake *fakeWorker) ResolvePublishedPath(_ string, components []string) (string, error) {
	return filepath.Join(append([]string{"/downloads"}, components...)...), nil
}

type fakePlanner struct {
	calls    int
	positive bool
	cases    []lidarrcontracts.Case
}

func (fake *fakePlanner) PlanLidarr(
	_ context.Context,
	repairCase lidarrcontracts.Case,
) (lidarrcontracts.Decision, error) {
	fake.calls++
	fake.cases = append(fake.cases, repairCase)
	if fake.positive {
		capability := repairCase.Capabilities[0]
		return lidarrcontracts.Decision{
			Kind: lidarrcontracts.ActionImportMissingTracks,
			ImportMissingTracks: &lidarrcontracts.ImportMissingTracksDecision{
				SchemaVersion: lidarrcontracts.SchemaVersion, CaseID: repairCase.CaseID,
				Action:       string(lidarrcontracts.ActionImportMissingTracks),
				CapabilityID: capability.CapabilityID, AlbumID: capability.AlbumID,
				ReleaseID: capability.ReleaseID,
				Mappings: []lidarrcontracts.TrackMapping{{
					ArtifactID: capability.ArtifactIDs[0], TrackID: capability.TrackIDs[0],
				}},
				EvidenceRefs: []string{capability.CapabilityID, capability.ArtifactIDs[0]},
				Explanation:  "The test evidence identifies the missing track.",
			},
		}, nil
	}
	return lidarrcontracts.Decision{
		Kind: lidarrcontracts.ActionNoRepair,
		NoRepair: &lidarrcontracts.NoRepairDecision{
			SchemaVersion: lidarrcontracts.SchemaVersion, CaseID: repairCase.CaseID,
			Action: string(lidarrcontracts.ActionNoRepair), Reason: "unsupported_repair",
			EvidenceRefs: []string{}, Explanation: "The shadow test does not import.",
		},
	}, nil
}

func TestRunnerPlansOnceAndUsesDurableCache(t *testing.T) {
	t.Parallel()
	download := t.TempDir()
	archive := filepath.Join(download, "album.tar")
	if err := os.WriteFile(archive, []byte("tar"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, archiveSnapshot, err := findArchive(download)
	if err != nil {
		t.Fatal(err)
	}
	albumID, artistID := int64(3), int64(2)
	client := &fakeLidarr{
		queue: []lidarr.QueueRecord{{
			ID: 1, AlbumID: &albumID, ArtistID: &artistID, Title: "Artist - Album",
			Status: "completed", TrackedDownloadStatus: "warning",
			DownloadID: "download", OutputPath: download,
		}, {
			ID: 2, AlbumID: &albumID, ArtistID: &artistID, Title: "Ordinary warning",
			Status: "completed", TrackedDownloadStatus: "warning",
			DownloadID: "ordinary", OutputPath: t.TempDir(),
		}},
		imports: []lidarr.ManualImport{{
			Path: "/downloads/.media-repair/workspaces/workspace:test/01.flac",
			Name: "01.flac", SizeBytes: 100, ArtistID: 2, AlbumID: 3,
			AlbumReleaseID: 4, TrackIDs: []int64{5},
			AudioTags: &lidarr.AudioTags{
				Title: "Track", Artist: "Artist", Album: "Album", TrackNumbers: []int{1},
			},
		}},
	}
	worker := &fakeWorker{}
	planner := &fakePlanner{}
	store, err := NewStore(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	runner, err := NewRunner(client, worker, planner, store)
	if err != nil {
		t.Fatal(err)
	}
	runner.now = func() time.Time { return time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC) }

	first, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	second, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(archive); err != nil {
		t.Fatal(err)
	}
	third, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if first.Observed != 2 || first.Candidates != 1 || first.Planned != 1 ||
		first.NoRepair != 1 || second.Candidates != 1 || second.Cached != 1 ||
		third.Candidates != 0 || worker.calls != 2 || planner.calls != 1 {
		t.Fatalf(
			"first=%#v second=%#v third=%#v worker=%d planner=%d",
			first, second, third, worker.calls, planner.calls,
		)
	}
	if worker.directoryCalls != 4 {
		t.Fatalf("directory calls = %d", worker.directoryCalls)
	}
	wantWorkspaceID := workspaceID(1, archiveSnapshot.StableFingerprint())
	for _, got := range worker.tarWorkspaceIDs {
		if got != wantWorkspaceID {
			t.Fatalf("tar workspace ID = %q, want %q", got, wantWorkspaceID)
		}
	}
	record, found, err := store.Get(1)
	if err != nil || !found || len(record.Bindings) != 1 {
		t.Fatalf("record=%#v found=%v error=%v", record, found, err)
	}
	if record.Bindings[0].DownloadID != "download" {
		t.Fatalf("binding=%#v", record.Bindings[0])
	}
}

func TestFindArchiveRejectsAmbiguousDownload(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	for _, name := range []string{"one.tar", "two.TAR"} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte("tar"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := findArchive(directory); err == nil {
		t.Fatal("ambiguous archive was accepted")
	}
}

func TestRunnerRecoversIdentityAndPlansDirectoryAudio(t *testing.T) {
	t.Parallel()
	download := t.TempDir()
	if err := os.WriteFile(filepath.Join(download, "01.flac"), []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	client := &fakeLidarr{
		queue: []lidarr.QueueRecord{{
			ID: 9, Title: "Artist - Album",
			Status: "completed", TrackedDownloadStatus: "warning",
			DownloadID: "download", OutputPath: download,
		}},
		recoveredIdentity: lidarr.AlbumIdentity{AlbumID: 3, ArtistID: 2},
		recoveredFound:    true,
		imports: []lidarr.ManualImport{{
			Path: "/downloads/.media-repair/workspaces/workspace:test/01.flac",
			Name: "01.flac", SizeBytes: 100, ArtistID: 2, AlbumID: 3,
			AlbumReleaseID: 4, TrackIDs: []int64{5},
			AudioTags: &lidarr.AudioTags{
				Title: "Track", Artist: "Artist", Album: "Album", TrackNumbers: []int{1},
			},
		}},
	}
	worker := &fakeWorker{directoryAudio: true}
	planner := &fakePlanner{}
	store, err := NewStore(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	runner, err := NewRunner(client, worker, planner, store)
	if err != nil {
		t.Fatal(err)
	}

	first, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	second, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	record, found, err := store.Get(9)
	if err != nil || !found {
		t.Fatalf("record found = %v, error = %v", found, err)
	}
	if first.Candidates != 1 || first.Planned != 1 || second.Cached != 1 ||
		worker.directoryCalls != 2 || planner.calls != 1 || client.identityReads != 2 ||
		record.SourceKind != SourceDirectoryAudio || record.SourcePath != download {
		t.Fatalf(
			"first=%#v second=%#v worker=%d planner=%d record=%#v",
			first, second, worker.directoryCalls, planner.calls, record,
		)
	}
}

func TestRunnerRefreshesPositiveDirectoryPlanWhenCurrentEvidenceChanges(t *testing.T) {
	t.Parallel()
	assertRunnerRefreshesPositivePlan(t, false)
}

func TestRunnerRefreshesPositiveTarPlanWhenCurrentEvidenceChanges(t *testing.T) {
	t.Parallel()
	assertRunnerRefreshesPositivePlan(t, true)
}

func assertRunnerRefreshesPositivePlan(t *testing.T, tarSource bool) {
	t.Helper()
	download := t.TempDir()
	filename := "01.flac"
	if tarSource {
		filename = "album.tar"
	}
	if err := os.WriteFile(filepath.Join(download, filename), []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	albumID, artistID := int64(3), int64(2)
	client := &fakeLidarr{
		queue: []lidarr.QueueRecord{{
			ID: 9, AlbumID: &albumID, ArtistID: &artistID, Title: "Artist - Album",
			Status: "completed", TrackedDownloadStatus: "warning",
			DownloadID: "download", OutputPath: download,
		}},
		imports: []lidarr.ManualImport{{
			Path: "/downloads/.media-repair/workspaces/workspace:test/01.flac",
			Name: "01.flac", SizeBytes: 100, ArtistID: 2, AlbumID: 3,
			AlbumReleaseID: 4, TrackIDs: []int64{5},
			AudioTags: &lidarr.AudioTags{
				Title: "Track", Artist: "Artist", Album: "Album", TrackNumbers: []int{1},
			},
		}},
	}
	worker := &fakeWorker{directoryAudio: !tarSource}
	planner := &fakePlanner{positive: true}
	store, err := NewStore(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	runner, err := NewRunner(client, worker, planner, store)
	if err != nil {
		t.Fatal(err)
	}

	first, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	second, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	client.queue[0].ErrorMessage = "New planning evidence"
	third, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	record, found, err := store.Get(9)
	if err != nil || !found {
		t.Fatalf("record found = %v, error = %v", found, err)
	}
	if first.Planned != 1 || second.Cached != 1 || third.Planned != 1 ||
		third.Cached != 0 || planner.calls != 2 || len(planner.cases) != 2 ||
		planner.cases[0].CaseID == planner.cases[1].CaseID {
		t.Fatalf(
			"first=%#v second=%#v third=%#v planner=%d cases=%#v",
			first, second, third, planner.calls, planner.cases,
		)
	}
	decision, err := lidarrcontracts.DecodeDecision(record.Decision)
	if err != nil {
		t.Fatal(err)
	}
	if decision.CaseID() != planner.cases[1].CaseID {
		t.Fatalf("stored decision case = %q, want %q", decision.CaseID(), planner.cases[1].CaseID)
	}
	if tarSource && worker.calls != 3 {
		t.Fatalf("tar materialization calls = %d, want 3", worker.calls)
	}
}

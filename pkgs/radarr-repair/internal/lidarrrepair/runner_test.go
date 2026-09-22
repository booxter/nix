package lidarrrepair

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/fileidentity"
	"github.com/booxter/nix-config/radarr-repair/internal/lidarr"
	"github.com/booxter/nix-config/radarr-repair/lidarrcontracts"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/materialize"
)

type fakeLidarr struct {
	queue   []lidarr.QueueRecord
	imports []lidarr.ManualImport
}

func (fake *fakeLidarr) ReadQueue(context.Context) ([]lidarr.QueueRecord, error) {
	return fake.queue, nil
}

func (fake *fakeLidarr) ReadAlbum(context.Context, int64) (lidarr.Album, error) {
	return lidarr.Album{
		ID: 3, ArtistID: 2, ArtistName: "Artist", Title: "Album", Monitored: true,
		Releases: []lidarr.Release{{
			ID: 4, Title: "Album", Format: "Album", TrackCount: 1,
			MediumCount: 1, Monitored: true,
		}},
	}, nil
}

func (fake *fakeLidarr) ReadTracks(context.Context, int64) ([]lidarr.Track, error) {
	return []lidarr.Track{{
		ID: 5, AlbumID: 3, ArtistID: 2, AbsoluteTrackNumber: 1,
		TrackNumber: "1", MediumNumber: 1, Title: "Track", DurationMS: 1000,
	}}, nil
}

func (fake *fakeLidarr) ReadManualImports(
	_ context.Context,
	query lidarr.ManualImportQuery,
) ([]lidarr.ManualImport, error) {
	if query.Folder != "/downloads/.media-repair/workspaces/workspace:test" {
		panic("unexpected manual-import workspace")
	}
	return fake.imports, nil
}

type fakeWorker struct {
	calls int
}

func (fake *fakeWorker) MaterializeTarAudio(
	context.Context,
	string,
	fileidentity.Snapshot,
	string,
) (materialize.Success, error) {
	fake.calls++
	duration := int64(1000)
	kind := workercontracts.FluffyAudio
	codec := "flac"
	return materialize.Success{
		SchemaVersion: materialize.SchemaVersion, RequestID: "request:test",
		Operation: materialize.OperationMaterializeTar, RootID: "usenet",
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
	}, nil
}

func (fake *fakeWorker) ResolvePublishedPath(_ string, components []string) (string, error) {
	return filepath.Join(append([]string{"/downloads"}, components...)...), nil
}

type fakePlanner struct {
	calls int
}

func (fake *fakePlanner) PlanLidarr(
	_ context.Context,
	repairCase lidarrcontracts.Case,
) (lidarrcontracts.Decision, error) {
	fake.calls++
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
	albumID, artistID := int64(3), int64(2)
	client := &fakeLidarr{
		queue: []lidarr.QueueRecord{{
			ID: 1, AlbumID: &albumID, ArtistID: &artistID, Title: "Artist - Album",
			Status: "completed", TrackedDownloadStatus: "warning",
			StatusMessages: []lidarr.StatusMessage{{
				Messages: []string{"Found archive file, might need to be extracted"},
			}},
			DownloadID: "download", OutputPath: download,
		}},
		imports: []lidarr.ManualImport{{
			Path: "/downloads/.media-repair/workspaces/workspace:test/01.flac",
			Name: "01.flac", SizeBytes: 100, ArtistID: 2, AlbumID: 3,
			AlbumReleaseID: 4, TrackIDs: []int64{5}, DownloadID: "download",
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
	if first.Planned != 1 || first.NoRepair != 1 || second.Cached != 1 ||
		worker.calls != 1 || planner.calls != 1 {
		t.Fatalf(
			"first=%#v second=%#v worker=%d planner=%d",
			first, second, worker.calls, planner.calls,
		)
	}
	record, found, err := store.Get(1)
	if err != nil || !found || len(record.Bindings) != 1 {
		t.Fatalf("record=%#v found=%v error=%v", record, found, err)
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

package lidarrrepair

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

type fakeLidarr struct {
	imports           []lidarr.ManualImport
	recoveredIdentity lidarr.AlbumIdentity
	recoveredFound    bool
}

func (fake *fakeLidarr) ReadQueue(context.Context) ([]lidarr.QueueRecord, error) {
	return nil, nil
}

func (fake *fakeLidarr) RecoverAlbumIdentity(
	context.Context,
	string,
) (lidarr.AlbumIdentity, bool, error) {
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
	directoryAudio bool
	archiveError   error
}

func (fake *fakeWorker) MaterializeRARAudio(
	_ context.Context,
	_ string,
	snapshot fileidentity.Snapshot,
	_ string,
) (materialize.Success, error) {
	if fake.archiveError != nil {
		return materialize.Success{}, fake.archiveError
	}
	return testMaterialization(materialize.OperationMaterializeRAR, snapshot.StableFingerprint()), nil
}

func (fake *fakeWorker) MaterializeTarAudio(
	_ context.Context,
	_ string,
	snapshot fileidentity.Snapshot,
	_ string,
) (materialize.Success, error) {
	if fake.archiveError != nil {
		return materialize.Success{}, fake.archiveError
	}
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

func TestEvidenceCollectorMaterializesSourcesAndRefreshesEvidence(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name       string
		filename   string
		sourceKind SourceKind
	}{
		{name: "tar", filename: "album.tar", sourceKind: SourceTarAudio},
		{name: "rar", filename: "album.rar", sourceKind: SourceRARAudio},
		{name: "directory", filename: "01.flac", sourceKind: SourceDirectoryAudio},
	} {
		t.Run(test.name, func(t *testing.T) {
			download := t.TempDir()
			if err := os.WriteFile(filepath.Join(download, test.filename), []byte("audio"), 0o600); err != nil {
				t.Fatal(err)
			}
			queue := evidenceQueue(download)
			client := evidenceClient()
			collector := NewEvidenceCollector(client, &fakeWorker{directoryAudio: true})
			collector.now = func() time.Time { return time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC) }

			first, err := collector.Inspect(context.Background(), queue, nil)
			if err != nil {
				t.Fatal(err)
			}
			if first.SourceKind != test.sourceKind || first.Case.Queue.QueueID != queue.ID ||
				len(first.Bindings) != 1 || first.Bindings[0].DownloadID != queue.DownloadID ||
				len(first.Case.Capabilities) != 1 {
				t.Fatalf("incomplete evidence: %#v", first)
			}
			queue.ErrorMessage = "New planning evidence"
			second, err := collector.Inspect(context.Background(), queue, nil)
			if err != nil {
				t.Fatal(err)
			}
			if first.Case.CaseID == second.Case.CaseID {
				t.Fatal("changed queue evidence retained the old case identity")
			}
		})
	}
}

func TestEvidenceCollectorRecoversAlbumIdentity(t *testing.T) {
	t.Parallel()
	queue := evidenceQueue(t.TempDir())
	queue.AlbumID = nil
	queue.ArtistID = nil
	client := evidenceClient()
	client.recoveredIdentity = lidarr.AlbumIdentity{AlbumID: 3, ArtistID: 2}
	client.recoveredFound = true
	collector := NewEvidenceCollector(client, &fakeWorker{directoryAudio: true})

	evidence, err := collector.Inspect(context.Background(), queue, nil)
	if err != nil {
		t.Fatal(err)
	}
	if evidence.Queue.AlbumID == nil || *evidence.Queue.AlbumID != 3 ||
		evidence.Queue.ArtistID == nil || *evidence.Queue.ArtistID != 2 ||
		evidence.SourceKind != SourceDirectoryAudio {
		t.Fatalf("recovered evidence = %#v", evidence)
	}
}

func TestEvidenceCollectorRejectsUnsupportedArchive(t *testing.T) {
	t.Parallel()
	download := t.TempDir()
	if err := os.WriteFile(filepath.Join(download, "album.rar"), []byte("not rar"), 0o600); err != nil {
		t.Fatal(err)
	}
	collector := NewEvidenceCollector(evidenceClient(), &fakeWorker{
		archiveError: &materialize.Rejection{Reason: materialize.FailureInvalidArchive},
	})
	if _, err := collector.Inspect(context.Background(), evidenceQueue(download), nil); !materialize.IsUnsupportedSource(err) {
		t.Fatalf("unsupported archive error = %v", err)
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
	if _, _, _, err := findArchive(directory); err == nil {
		t.Fatal("ambiguous archive was accepted")
	}
}

func evidenceQueue(download string) lidarr.QueueRecord {
	albumID, artistID := int64(3), int64(2)
	return lidarr.QueueRecord{
		ID: 9, AlbumID: &albumID, ArtistID: &artistID, Title: "Artist - Album",
		Status: "completed", TrackedDownloadStatus: "warning",
		DownloadID: "download", OutputPath: download,
	}
}

func evidenceClient() *fakeLidarr {
	return &fakeLidarr{imports: []lidarr.ManualImport{{
		Path: "/downloads/.media-repair/workspaces/workspace:test/01.flac",
		Name: "01.flac", SizeBytes: 100, ArtistID: 2, AlbumID: 3,
		AlbumReleaseID: 4, TrackIDs: []int64{5},
		AudioTags: &lidarr.AudioTags{
			Title: "Track", Artist: "Artist", Album: "Album", TrackNumbers: []int{1},
		},
	}}}
}

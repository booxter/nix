package lidarrrepair

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

type fakeLidarr struct {
	imports           []lidarr.ManualImport
	tracksErr         error
	importsErr        error
	trackInLibrary    bool
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
	if fake.tracksErr != nil {
		return nil, fake.tracksErr
	}
	if albumID != 3 || releaseID != 4 {
		return nil, nil
	}
	return []lidarr.Track{{
		ID: 5, AlbumID: 3, ReleaseID: 4, ArtistID: 2, AbsoluteTrackNumber: 1,
		TrackNumber: "1", MediumNumber: 1, Title: "Track", DurationMS: 1000,
		HasFile: fake.trackInLibrary,
	}}, nil
}

func (fake *fakeLidarr) ReadManualImports(
	_ context.Context,
	query lidarr.ManualImportQuery,
) ([]lidarr.ManualImport, error) {
	if fake.importsErr != nil {
		return nil, fake.importsErr
	}
	var matches []lidarr.ManualImport
	for _, item := range fake.imports {
		if filepath.Dir(item.Path) == query.Folder && item.ArtistID == query.ArtistID {
			matches = append(matches, item)
		}
	}
	return matches, nil
}

type fakeWorker struct {
	root           string
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

const testAudio = "recorded audio"

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
			RelativePath: "01.flac", SizeBytes: int64(len(testAudio)),
			Fingerprint: fmt.Sprintf("sha256:%x", sha256.Sum256([]byte(testAudio))),
			Evidence: workercontracts.Evidence{
				Format: workercontracts.Format{
					Names: []string{"flac"}, DurationMS: &duration, SizeBytes: pointer(int64(len(testAudio))),
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
	return filepath.Join(append([]string{fake.root}, components...)...), nil
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
			client := evidenceClient("/downloads")
			collector := NewEvidenceCollector(client, &fakeWorker{root: "/downloads", directoryAudio: true})
			collector.now = func() time.Time { return time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC) }

			first := requireAlbumEvidence(t, collector.Inspect(context.Background(), queue, nil))
			if first.SourceKind != test.sourceKind || first.Case.Queue.QueueID != queue.ID ||
				len(first.Bindings) != 1 || first.Bindings[0].DownloadID != queue.DownloadID {
				t.Fatalf("incomplete evidence: %#v", first)
			}

			tracks := first.Case.Tracks
			if len(tracks) != 1 || tracks[0].TrackID != 5 || tracks[0].ReleaseID != 4 {
				t.Fatalf("unexpected album tracks: %+v", tracks)
			}
			files := first.Case.Artifacts
			if len(files) != 1 || files[0].RelativePath != "01.flac" {
				t.Fatalf("unexpected audio files: %+v", files)
			}
			options := first.Case.Capabilities
			if len(options) != 1 {
				t.Fatalf("expected one import option, got %+v", options)
			}
			option := options[0]
			if option.Action != string(lidarrcontracts.ActionImportMissingTracks) || option.AlbumID != 3 ||
				option.ReleaseID != 4 || !slices.Equal(option.TrackIDs, []int64{5}) ||
				!slices.Equal(option.ArtifactIDs, []string{files[0].ArtifactID}) {
				t.Fatalf("unexpected import option: %+v", option)
			}

			queue.ErrorMessage = "New planning evidence"
			second := requireAlbumEvidence(t, collector.Inspect(context.Background(), queue, nil))
			if first.Case.CaseID == second.Case.CaseID {
				t.Fatal("changed queue evidence retained the old case identity")
			}
		})
	}
}

func TestAlbumInspectionStopsWhenLidarrCannotSupplyFacts(t *testing.T) {
	t.Parallel()
	unavailable := errors.New("Lidarr unavailable")
	for _, test := range []struct {
		name   string
		client fakeLidarr
	}{
		{"release tracks", fakeLidarr{tracksErr: unavailable}},
		{"manual imports", fakeLidarr{importsErr: unavailable}},
	} {
		t.Run(test.name, func(t *testing.T) {
			collector := NewEvidenceCollector(&test.client, &fakeWorker{root: "/downloads", directoryAudio: true})
			result := collector.Inspect(t.Context(), evidenceQueue(t.TempDir()), nil)
			if result.Case != nil || !errors.Is(result.Err, unavailable) {
				t.Fatalf("expected inspection to stop with the Lidarr error, got %+v", result)
			}
		})
	}
}

func TestEvidenceCollectorRecoversAlbumIdentity(t *testing.T) {
	t.Parallel()
	queue := evidenceQueue(t.TempDir())
	queue.AlbumID = nil
	queue.ArtistID = nil
	client := evidenceClient("/downloads")
	client.recoveredIdentity = lidarr.AlbumIdentity{AlbumID: 3, ArtistID: 2}
	client.recoveredFound = true
	collector := NewEvidenceCollector(client, &fakeWorker{root: "/downloads", directoryAudio: true})

	evidence := requireAlbumEvidence(t, collector.Inspect(context.Background(), queue, nil))
	if evidence.Queue.AlbumID == nil || *evidence.Queue.AlbumID != 3 ||
		evidence.Queue.ArtistID == nil || *evidence.Queue.ArtistID != 2 ||
		evidence.SourceKind != SourceDirectoryAudio {
		t.Fatalf("recovered evidence = %#v", evidence)
	}
}

func TestAlbumInspectionLeavesActiveAndFinishedImportsToLidarr(t *testing.T) {
	queue := evidenceQueue(t.TempDir())
	collector := NewEvidenceCollector(evidenceClient("/downloads"), &fakeWorker{root: "/downloads", directoryAudio: true})
	for _, state := range []string{"importing", "imported"} {
		queue.TrackedDownloadState = state
		result := collector.Inspect(t.Context(), queue, nil)
		if result.Err != nil || result.Case != nil || !slices.Contains(result.Findings, "unsupported_queue_state") {
			t.Fatalf("queue state %s: %+v", state, result)
		}
	}
}

func TestEvidenceCollectorRejectsUnsupportedArchive(t *testing.T) {
	t.Parallel()
	download := t.TempDir()
	if err := os.WriteFile(filepath.Join(download, "album.rar"), []byte("not rar"), 0o600); err != nil {
		t.Fatal(err)
	}
	collector := NewEvidenceCollector(evidenceClient("/downloads"), &fakeWorker{
		archiveError: &materialize.Rejection{Reason: materialize.FailureInvalidArchive},
	})
	result := collector.Inspect(context.Background(), evidenceQueue(download), nil)
	if !materialize.IsUnsupportedSource(result.Err) {
		t.Fatalf("unsupported archive error = %v", result.Err)
	}
}

func TestEvidenceCollectorRejectsAmbiguousDownload(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	for _, name := range []string{"one.tar", "two.TAR"} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte("tar"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	collector := NewEvidenceCollector(evidenceClient("/downloads"), &fakeWorker{})
	result := collector.Inspect(context.Background(), evidenceQueue(directory), nil)
	if result.Err == nil || !strings.Contains(result.Err.Error(), "multiple supported archives") {
		t.Fatalf("expected an ambiguous download error, got %v", result.Err)
	}
}

func requireAlbumEvidence(t *testing.T, result CollectionResult) *Evidence {
	t.Helper()
	if result.Case == nil {
		t.Fatalf("expected album evidence, got findings %v and error %v", result.Findings, result.Err)
	}
	return result.Case
}

func TestAlbumWithBytesRemainingWaitsForDownload(t *testing.T) {
	queue := evidenceQueue(t.TempDir())
	queue.SizeRemainingBytes = 1
	collector := NewEvidenceCollector(&fakeLidarr{}, &fakeWorker{})
	result := collector.Inspect(t.Context(), queue, nil)
	if result.Err != nil || result.Case != nil || !slices.Contains(result.Findings, "incomplete_download") {
		t.Fatalf("expected an incomplete download, got %+v", result)
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

func evidenceClient(root string) *fakeLidarr {
	return &fakeLidarr{imports: []lidarr.ManualImport{{
		Path: filepath.Join(root, ".media-repair/workspaces/workspace:test/01.flac"),
		Name: "01.flac", SizeBytes: int64(len(testAudio)), ArtistID: 2, AlbumID: 3,
		AlbumReleaseID: 4, TrackIDs: []int64{5},
		AudioTags: &lidarr.AudioTags{
			Title: "Track", Artist: "Artist", Album: "Album", TrackNumbers: []int{1},
		},
	}}}
}

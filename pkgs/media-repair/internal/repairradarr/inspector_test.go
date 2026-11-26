package repairradarr

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/archivematerialize"
	"github.com/booxter/nix-config/media-repair/internal/controller"
)

const testDownloadHash = "abcdef0123456789abcdef0123456789abcdef01"

func TestInspectCollectsOneEligibleCandidate(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	inspector := newTestInspector(t, fixture.dependencies())

	assembly, err := inspector.Inspect(context.Background(), fixture.record)
	if err != nil {
		t.Fatal(err)
	}
	result := assembly.Request
	if !result.ObservedAt.Equal(fixture.clock.now) || result.Radarr.Movie == nil ||
		result.Radarr.Movie.Title != fixture.radarr.movie.Title || result.Radarr.Failure.Title != fixture.record.Title ||
		len(result.Radarr.History) != 1 || len(result.Radarr.ManualImports) != 1 ||
		len(result.Files) != 2 || result.Files[0].FileID != "file:one" ||
		result.Files[1].FileID != "file:two" || result.Files[0].Probe.Status != contracts.Ok ||
		result.Files[1].Probe.Status != contracts.Ok {
		t.Fatalf("assembled case = %#v", result)
	}
	if fixture.transmission.downloadID != strings.ToUpper(testDownloadHash) {
		t.Fatalf("Transmission download ID = %q", fixture.transmission.downloadID)
	}
	wantQuery := controller.RadarrManualImportQuery{
		MovieID: 42, DownloadID: strings.ToUpper(testDownloadHash), Folder: "/downloads/Example_Movie",
	}
	if fixture.radarr.manualImportQuery != wantQuery {
		t.Fatalf("manual-import query = %#v, want %#v", fixture.radarr.manualImportQuery, wantQuery)
	}
}

func TestInspectBuildsCaseForCompletedSABOutputTree(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	const downloadID = "998d2f1f-cb49-4714-be1e-875f03e1f3c2"
	record := fixture.record
	record.DownloadID = downloadID
	record.Protocol = "usenet"
	record.DownloadClient = "SABnzbd"
	record.OutputPath = "/downloads/Robin.Hood"
	record.SizeBytes = 32_596_371_005
	fixture.radarr.history = []controller.RadarrHistoryEvent{{
		ID: 501, MovieID: 42, DownloadID: downloadID, EventType: "grabbed",
		OccurredAt:  fixture.clock.now.Add(-time.Hour),
		SourceTitle: "The.Death.Of.Robin.Hood.2026.1080p.BluRay.H264",
	}}
	fixture.radarr.imports = nil
	fixture.transmission = &fakeTransmission{
		protocol: "usenet", clientName: "SABnzbd", found: true,
		torrent: controller.Download{
			Client: controller.DownloadClientSABnzbd, SourceType: controller.DownloadSourceUsenet,
			ID: downloadID, IDComparison: controller.DownloadIDExact,
			Name:   "duplicate-the.death.of.robin.hood.2026.1080p.bluray.h264",
			Stable: true, Complete: true, OutputPath: record.OutputPath,
			TotalSizeBytes:   34_265_436_989,
			ContentOwnership: controller.DownloadContentOutputTree,
			Files:            []controller.DownloadFile{},
		},
	}
	file := inventoryFile(
		"file:one",
		"duplicate-the.death.of.robin.hood.2026.1080p.bluray.h264.mkv",
		32_596_371_005,
		10,
		0,
	)
	file.DownloadFile.HasIndex = false
	fixture.files.inventory = controller.FileInventory{
		Files: []controller.InventoryFile{file},
		Paths: []controller.FilePathMapping{{
			FileID:       file.ID,
			AbsolutePath: record.OutputPath + "/" + file.PathComponents[0],
		}},
	}
	fixture.probes.outcome = controller.FailedMediaProbe(
		controller.MediaProbeUnsupportedFormat,
	)

	inspector := newTestInspector(t, fixture.dependencies())
	assembly, err := inspector.Inspect(context.Background(), record)
	if err != nil {
		t.Fatal(err)
	}
	if assembly.Request.Download.Client != contracts.Sabnzbd ||
		assembly.Request.Download.SourceType != contracts.Usenet ||
		assembly.Request.Download.ContentOwnership != contracts.OutputTree {
		t.Fatalf("download evidence = %#v", assembly.Request.Download)
	}
	if len(assembly.Request.Files) != 1 ||
		assembly.Request.Files[0].DownloadMembership == nil ||
		assembly.Request.Files[0].DownloadMembership.SourceIndex != nil {
		t.Fatalf("file evidence = %#v", assembly.Request.Files)
	}
	encoded, err := contracts.EncodeCase(assembly.Request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := contracts.DecodeCase(encoded); err != nil {
		t.Fatalf("decode assembled case: %v", err)
	}
}

func TestInspectUsesMaterializedArchiveVideo(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	fixture.radarr.imports = nil
	materializedFile := controller.InventoryFile{
		ID: "artifact:movie", PathComponents: []string{"Movie", "movie.mkv"},
		Fingerprint: controller.FileFingerprint{Device: 2, Inode: 3, SizeBytes: 100, MTimeNS: 4},
		DownloadFile: &controller.DownloadFileReference{
			LengthBytes: 100, BytesCompleted: 100, Selected: true,
		},
	}
	fixture.archives = &fakeArchiveMaterializer{
		found: true,
		source: archivematerialize.Source{
			Root: "/downloads/.media-repair/workspaces/archive",
			Inventory: controller.FileInventory{
				Files: []controller.InventoryFile{materializedFile},
				Paths: []controller.FilePathMapping{{
					FileID:       materializedFile.ID,
					AbsolutePath: "/downloads/.media-repair/workspaces/archive/Movie/movie.mkv",
				}},
			},
			Probes: []controller.FileProbe{{
				FileID:  materializedFile.ID,
				Outcome: controller.SuccessfulMediaProbe(testProbeEvidence(100)),
			}},
		},
	}
	inspector := newTestInspector(t, fixture.dependencies())

	assembly, err := inspector.Inspect(context.Background(), fixture.record)
	if err != nil {
		t.Fatal(err)
	}
	if len(assembly.Request.Files) != 1 || assembly.Request.Files[0].FileID != string(materializedFile.ID) ||
		assembly.Request.Files[0].Probe.Status != contracts.Ok {
		t.Fatalf("archive source was not used: %#v", assembly.Request.Files)
	}
	if fixture.radarr.manualImportQuery.Folder != fixture.archives.source.Root {
		t.Fatalf("manual import folder = %q, want %q", fixture.radarr.manualImportQuery.Folder, fixture.archives.source.Root)
	}
}

func TestInspectRecoversMovieIDFromHistory(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	fixture.record.MovieID = nil
	fixture.record.ErrorMessage = "A download client diagnostic"
	fixture.record.StatusMessages = nil
	fixture.radarr.recoveredMovieID = 42
	fixture.radarr.recoveredMovieFound = true
	inspector := newTestInspector(t, fixture.dependencies())

	assembly, err := inspector.Inspect(context.Background(), fixture.record)
	if err != nil {
		t.Fatal(err)
	}
	radarr := assembly.Request.Radarr
	if radarr.Movie == nil || radarr.Movie.Title != fixture.radarr.movie.Title ||
		len(radarr.History) != 1 || len(radarr.ManualImports) != 1 {
		t.Fatalf("recovered movie-specific evidence = %#v", radarr)
	}
	if radarr.Failure.ErrorMessage != "A download client diagnostic" ||
		len(radarr.Failure.StatusMessages) != 0 {
		t.Fatalf("queue evidence = %#v", radarr.Failure)
	}
}

func TestInspectRejectsIneligibleRecord(t *testing.T) {
	t.Parallel()
	fixture := inspectionFixture()
	fixture.record.Protocol = "usenet"
	inspector := newTestInspector(t, fixture.dependencies())
	_, err := inspector.Inspect(context.Background(), fixture.record)
	if err == nil || !strings.Contains(err.Error(), "record 71 is ineligible") {
		t.Fatalf("error = %v", err)
	}
}

func TestInspectRejectsUnsafeOrIncompleteCollection(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*inspectionTestFixture)
		want   string
	}{
		{
			name: "missing torrent",
			mutate: func(fixture *inspectionTestFixture) {
				fixture.transmission.found = false
			},
			want: "was not found",
		},
		{
			name: "ineligible correlation",
			mutate: func(fixture *inspectionTestFixture) {
				fixture.transmission.torrent.ID = "abcdef0123456789abcdef0123456789abcdef02"
			},
			want: "ineligible download correlation",
		},
		{
			name: "missing candidate path",
			mutate: func(fixture *inspectionTestFixture) {
				fixture.files.inventory.Paths = fixture.files.inventory.Paths[:1]
			},
			want: "has no local path",
		},
		{
			name: "probe failure",
			mutate: func(fixture *inspectionTestFixture) {
				fixture.probes.err = errors.New("worker unavailable")
			},
			want: "probe candidate file",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := inspectionFixture()
			test.mutate(&fixture)
			inspector := newTestInspector(t, fixture.dependencies())
			_, err := inspector.Inspect(context.Background(), fixture.record)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestInspectHonorsCancellationBeforeReading(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	inspector := newTestInspector(t, fixture.dependencies())
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := inspector.Inspect(ctx, fixture.record); !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v", err)
	}
}

func TestNewInspectorRejectsMissingCollectionTimeout(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	dependencies := fixture.dependencies()
	dependencies.CollectionTimeout = 0
	if _, err := NewInspector(dependencies); err == nil ||
		!strings.Contains(err.Error(), "collection timeout") {
		t.Fatalf("error = %v", err)
	}
}

func TestZeroValueInspectorIsUnconfigured(t *testing.T) {
	t.Parallel()

	var inspector Inspector
	if _, err := inspector.Inspect(context.Background(), controller.RadarrQueueRecord{}); err == nil ||
		!strings.Contains(err.Error(), "inspector is not configured") {
		t.Fatalf("error = %v", err)
	}
}

func TestInspectRetainsProbeFailuresAndEvidenceOnlyFiles(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	extra := inventoryFile("file:notes", "README.txt", 100, 12, 2)
	fixture.files.inventory.Files = append(fixture.files.inventory.Files, extra)
	fixture.files.inventory.Paths = append(fixture.files.inventory.Paths, controller.FilePathMapping{
		FileID: extra.ID, AbsolutePath: "/downloads/Example_Movie/README.txt",
	})
	fixture.probes.outcome = controller.FailedMediaProbe(
		controller.MediaProbeUnsupportedFormat,
	)
	inspector := newTestInspector(t, fixture.dependencies())
	assembly, err := inspector.Inspect(context.Background(), fixture.record)
	if err != nil {
		t.Fatal(err)
	}
	files := assembly.Request.Files
	if len(files) != 3 || files[0].Probe.Status != contracts.Failed ||
		files[1].Probe.Status != contracts.Failed || files[2].Probe.Status != contracts.NotProbed ||
		files[2].Probe.Reason == nil || string(*files[2].Probe.Reason) != "not_probe_candidate" {
		t.Fatalf("probe outcomes = %#v", files)
	}
}

func TestInspectRetainsCollectionDeadlineAsIncompleteEvidence(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	fixture.probes.waitForCancellation = true
	dependencies := fixture.dependencies()
	dependencies.CollectionTimeout = 20 * time.Millisecond
	inspector := newTestInspector(t, dependencies)
	assembly, err := inspector.Inspect(context.Background(), fixture.record)
	if err != nil {
		t.Fatal(err)
	}
	if len(assembly.Request.Files) != 2 {
		t.Fatalf("files = %#v", assembly.Request.Files)
	}
	for _, file := range assembly.Request.Files {
		if file.Probe.Status != contracts.NotProbed || file.Probe.Reason == nil ||
			string(*file.Probe.Reason) != "collection_limit" {
			t.Fatalf("probe outcome = %#v", file.Probe)
		}
	}
}

type inspectionTestFixture struct {
	record       controller.RadarrQueueRecord
	clock        *fakeClock
	radarr       *fakeRadarr
	transmission *fakeTransmission
	files        *fakeFiles
	probes       *fakeProbes
	archives     *fakeArchiveMaterializer
}

func inspectionFixture() inspectionTestFixture {
	record, torrent := eligibleDownload()
	first := inventoryFile("file:one", "CD1.mkv", 1_000, 10, 0)
	second := inventoryFile("file:two", "CD2.mkv", 2_000, 11, 1)
	return inspectionTestFixture{
		record: record,
		clock:  &fakeClock{now: time.Date(2026, time.September, 7, 18, 0, 0, 0, time.UTC)},
		radarr: &fakeRadarr{
			movie: controller.RadarrMovie{ID: 42, TMDBID: 1234, Title: "Example Movie", Year: 2024},
			history: []controller.RadarrHistoryEvent{{
				ID: 501, MovieID: 42, DownloadID: record.DownloadID,
				EventType: "grabbed", OccurredAt: time.Date(2026, time.September, 7, 17, 0, 0, 0, time.UTC),
				SourceTitle: "Example.Movie.2024",
			}},
			imports: []controller.RadarrManualImport{{Path: "/downloads/Example_Movie/CD1.mkv", SizeBytes: 1_000}},
		},
		transmission: &fakeTransmission{torrent: torrent, found: true},
		files: &fakeFiles{inventory: controller.FileInventory{
			Files: []controller.InventoryFile{first, second},
			Paths: []controller.FilePathMapping{
				{FileID: first.ID, AbsolutePath: "/downloads/Example_Movie/CD1.mkv"},
				{FileID: second.ID, AbsolutePath: "/downloads/Example_Movie/CD2.mkv"},
			},
		}},
		probes: &fakeProbes{files: map[string]controller.FileFingerprint{
			"/downloads/Example_Movie/CD1.mkv": first.Fingerprint,
			"/downloads/Example_Movie/CD2.mkv": second.Fingerprint,
		}},
	}
}

func (fixture inspectionTestFixture) dependencies() InspectorConfig {
	dependencies := InspectorConfig{
		Clock: fixture.clock, Radarr: fixture.radarr, Downloads: fixture.transmission,
		Files: fixture.files, Probes: fixture.probes, CollectionTimeout: time.Minute,
	}
	if fixture.archives != nil {
		dependencies.Archives = fixture.archives
	}
	return dependencies
}

type fakeArchiveMaterializer struct {
	source archivematerialize.Source
	found  bool
	err    error
}

func (materializer *fakeArchiveMaterializer) MaterializeVideo(
	context.Context,
	int64,
	controller.FileInventory,
) (archivematerialize.Source, bool, error) {
	return materializer.source, materializer.found, materializer.err
}

func eligibleDownload() (controller.RadarrQueueRecord, controller.Download) {
	movieID := int64(42)
	record := controller.RadarrQueueRecord{
		ID: 71, MovieID: &movieID, Title: "Example.Movie.2024", Status: "completed",
		TrackedDownloadStatus: "warning", TrackedDownloadState: "importBlocked",
		StatusMessages: []controller.RadarrStatusMessage{{
			Title: "CD1.mkv",
			Messages: []string{
				"File is suspected multi-part file, Radarr doesn't support this",
			},
		}},
		DownloadID: strings.ToUpper(testDownloadHash), Protocol: "torrent",
		DownloadClient: "Transmission",
		OutputPath:     "/downloads/Example_Movie",
	}
	torrent := controller.Download{
		Client: controller.DownloadClientTransmission, SourceType: controller.DownloadSourceTorrent,
		ID: testDownloadHash, IDComparison: controller.DownloadIDASCIIInsensitive,
		Name: "Example:Movie", Stable: true, Complete: true,
		OutputPath: "/downloads/Example_Movie", TotalSizeBytes: 3_000,
		ContentOwnership: controller.DownloadContentManifest,
		Files: []controller.DownloadFile{
			{Index: 0, HasIndex: true, Path: "/downloads/Example_Movie/CD1.mkv", LengthBytes: 1_000, BytesCompleted: 1_000, Selected: true},
			{Index: 1, HasIndex: true, Path: "/downloads/Example_Movie/CD2.mkv", LengthBytes: 2_000, BytesCompleted: 2_000, Selected: true},
		},
	}
	return record, torrent
}

func inventoryFile(
	id controller.FileID,
	name string,
	size int64,
	inode uint64,
	torrentIndex int,
) controller.InventoryFile {
	return controller.InventoryFile{
		ID: id, PathComponents: []string{name},
		Fingerprint: controller.FileFingerprint{Device: 1, Inode: inode, SizeBytes: size, MTimeNS: 100},
		DownloadFile: &controller.DownloadFileReference{
			Index: torrentIndex, HasIndex: true, LengthBytes: size, BytesCompleted: size, Selected: true,
		},
	}
}

func newTestInspector(t *testing.T, dependencies InspectorConfig) *Inspector {
	t.Helper()
	inspector, err := NewInspector(dependencies)
	if err != nil {
		t.Fatal(err)
	}
	return inspector
}

type fakeClock struct {
	now time.Time
}

func (clock *fakeClock) Now() time.Time {
	return clock.now
}

type fakeRadarr struct {
	movie               controller.RadarrMovie
	history             []controller.RadarrHistoryEvent
	imports             []controller.RadarrManualImport
	manualImportQuery   controller.RadarrManualImportQuery
	recoveredMovieID    int64
	recoveredMovieFound bool
}

func (reader *fakeRadarr) RecoverMovieID(context.Context, string) (int64, bool, error) {
	return reader.recoveredMovieID, reader.recoveredMovieFound, nil
}

func (reader *fakeRadarr) ReadMovie(context.Context, int64) (controller.RadarrMovie, error) {
	return reader.movie, nil
}

func (reader *fakeRadarr) ReadHistory(
	context.Context,
	int64,
	string,
) ([]controller.RadarrHistoryEvent, error) {
	return reader.history, nil
}

func (reader *fakeRadarr) ReadManualImports(
	_ context.Context,
	query controller.RadarrManualImportQuery,
) ([]controller.RadarrManualImport, error) {
	reader.manualImportQuery = query
	return reader.imports, nil
}

type fakeTransmission struct {
	torrent    controller.Download
	found      bool
	downloadID string
	protocol   controller.DownloadProtocol
	clientName string
}

func (reader *fakeTransmission) Supports(
	protocol controller.DownloadProtocol,
	clientName string,
) bool {
	wantProtocol := reader.protocol
	if wantProtocol == "" {
		wantProtocol = "torrent"
	}
	wantClientName := reader.clientName
	if wantClientName == "" {
		wantClientName = "Transmission"
	}
	return protocol == wantProtocol && clientName == wantClientName
}

func (reader *fakeTransmission) Resolve(
	ctx context.Context,
	record controller.RadarrQueueRecord,
) (controller.Download, bool, error) {
	return reader.FindDownload(ctx, record.DownloadID)
}

func (reader *fakeTransmission) FindDownload(
	_ context.Context,
	downloadID string,
) (controller.Download, bool, error) {
	reader.downloadID = downloadID
	return reader.torrent, reader.found, nil
}

type fakeFiles struct {
	inventory controller.FileInventory
}

func (reader *fakeFiles) Inventory(
	context.Context,
	controller.DownloadCorrelation,
) (controller.FileInventory, error) {
	return reader.inventory, nil
}

func testProbeEvidence(size int64) controller.ProbeEvidence {
	kind := controller.ProbeStreamVideo
	codec := "h264"
	flag := false
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{Names: []string{"matroska"}, SizeBytes: &size},
		Streams: []controller.ProbeStream{{
			Kind: &kind, CodecName: &codec,
			TimeBase: &controller.Rational{Numerator: 1, Denominator: 1000},
			Disposition: &controller.ProbeDisposition{
				Default: &flag, Forced: &flag, HearingImpaired: &flag, VisualImpaired: &flag,
			},
		}},
	}
}

type fakeProbes struct {
	outcome             controller.MediaProbeOutcome
	err                 error
	waitForCancellation bool
	files               map[string]controller.FileFingerprint
}

func (reader *fakeProbes) Probe(
	ctx context.Context,
	target controller.MediaProbeTarget,
) (controller.MediaProbeOutcome, error) {
	if reader.waitForCancellation {
		<-ctx.Done()
		return controller.MediaProbeOutcome{}, ctx.Err()
	}
	if reader.err != nil {
		return controller.MediaProbeOutcome{}, reader.err
	}
	if reader.outcome.Status != "" {
		return reader.outcome, nil
	}
	fingerprint, found := reader.files[target.AbsolutePath]
	if !found || fingerprint != target.Fingerprint {
		return controller.MediaProbeOutcome{}, errors.New("probe target does not match a fixture file")
	}
	return controller.SuccessfulMediaProbe(testProbeEvidence(target.Fingerprint.SizeBytes)), nil
}

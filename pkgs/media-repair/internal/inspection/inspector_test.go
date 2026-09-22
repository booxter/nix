package inspection

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
)

const testDownloadHash = "abcdef0123456789abcdef0123456789abcdef01"

func TestInspectCollectsOneEligibleCandidate(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	var observed casebuilder.Observation
	wantAssembly := casebuilder.Assembly{EncodedRequest: []byte("assembled")}
	inspector := newTestInspector(t, fixture.dependencies(), func(
		observation casebuilder.Observation,
	) (casebuilder.Assembly, error) {
		observed = observation
		return wantAssembly, nil
	})

	assembly, err := inspector.Inspect(context.Background(), Selection{})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(assembly, wantAssembly) {
		t.Fatalf("assembly = %#v, want %#v", assembly, wantAssembly)
	}
	if !observed.ObservedAt.Equal(fixture.clock.now) ||
		!reflect.DeepEqual(observed.Movie, &fixture.radarr.movie) ||
		!reflect.DeepEqual(observed.History, fixture.radarr.history) ||
		!reflect.DeepEqual(observed.ManualImports, fixture.radarr.imports) ||
		!reflect.DeepEqual(observed.Inventory, fixture.files.inventory) {
		t.Fatalf("assembled observation is incomplete: %#v", observed)
	}
	if !observed.Correlation.Eligible() ||
		observed.Correlation.DownloadRoot != "/downloads/Example_Movie" {
		t.Fatalf("correlation = %#v", observed.Correlation)
	}
	if len(observed.Probes) != 2 || observed.Probes[0].FileID != "file:one" ||
		observed.Probes[1].FileID != "file:two" {
		t.Fatalf("probes = %#v", observed.Probes)
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
	wantTargets := []controller.MediaProbeTarget{
		{AbsolutePath: "/downloads/Example_Movie/CD1.mkv", Fingerprint: fixture.files.inventory.Files[0].Fingerprint},
		{AbsolutePath: "/downloads/Example_Movie/CD2.mkv", Fingerprint: fixture.files.inventory.Files[1].Fingerprint},
	}
	if !reflect.DeepEqual(fixture.probes.targets, wantTargets) {
		t.Fatalf("probe targets = %#v, want %#v", fixture.probes.targets, wantTargets)
	}
}

func TestInspectBuildsCaseForCompletedSABOutputTree(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	const downloadID = "998d2f1f-cb49-4714-be1e-875f03e1f3c2"
	record := fixture.radarr.records[0]
	record.DownloadID = downloadID
	record.Protocol = "usenet"
	record.DownloadClient = "SABnzbd"
	record.OutputPath = "/downloads/Robin.Hood"
	record.SizeBytes = 32_596_371_005
	fixture.radarr.records = []controller.RadarrQueueRecord{record}
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

	inspector := newTestInspector(t, fixture.dependencies(), casebuilder.Assemble)
	assembly, err := inspector.Inspect(context.Background(), Selection{})
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
	if _, err := contracts.DecodeCase(assembly.EncodedRequest); err != nil {
		t.Fatalf("decode assembled case: %v", err)
	}
}

func TestInspectSelectsAnExplicitEligibleCandidate(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	other := fixture.radarr.records[0]
	other.ID = 72
	fixture.radarr.records = append([]controller.RadarrQueueRecord{other}, fixture.radarr.records...)
	var selectedQueueID int64
	inspector := newTestInspector(t, fixture.dependencies(), func(
		observation casebuilder.Observation,
	) (casebuilder.Assembly, error) {
		selectedQueueID = observation.Correlation.Radarr.ID
		return casebuilder.Assembly{}, nil
	})

	if _, err := inspector.Inspect(context.Background(), Selection{QueueID: 71}); err != nil {
		t.Fatal(err)
	}
	if selectedQueueID != 71 {
		t.Fatalf("selected queue ID = %d", selectedQueueID)
	}
}

func TestInspectAllCollectsEveryEligibleCandidateFromOneQueueRead(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	other := fixture.radarr.records[0]
	other.ID = 72
	fixture.radarr.records = append(fixture.radarr.records, other)
	var selectedQueueIDs []int64
	inspector := newTestInspector(t, fixture.dependencies(), func(
		observation casebuilder.Observation,
	) (casebuilder.Assembly, error) {
		selectedQueueIDs = append(selectedQueueIDs, observation.Correlation.Radarr.ID)
		return casebuilder.Assembly{EncodedRequest: []byte("assembled")}, nil
	})

	result, err := inspector.InspectAll(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	assemblies := result.Assemblies
	if len(assemblies) != 2 || !reflect.DeepEqual(selectedQueueIDs, []int64{71, 72}) {
		t.Fatalf("assemblies = %d, queue IDs = %v", len(assemblies), selectedQueueIDs)
	}
	if fixture.radarr.queueReads != 1 {
		t.Fatalf("Radarr queue reads = %d", fixture.radarr.queueReads)
	}
}

func TestInspectAllReturnsSuccessfulCasesAlongsideCollectionErrors(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	other := fixture.radarr.records[0]
	other.ID = 72
	fixture.radarr.records = append(fixture.radarr.records, other)
	var selectedQueueIDs []int64
	inspector := newTestInspector(t, fixture.dependencies(), func(
		observation casebuilder.Observation,
	) (casebuilder.Assembly, error) {
		queueID := observation.Correlation.Radarr.ID
		selectedQueueIDs = append(selectedQueueIDs, queueID)
		if queueID == 71 {
			return casebuilder.Assembly{}, errors.New("cannot assemble")
		}
		return casebuilder.Assembly{EncodedRequest: []byte("assembled")}, nil
	})

	result, err := inspector.InspectAll(context.Background())
	assemblies := result.Assemblies
	if err == nil || !strings.Contains(err.Error(), "queue record 71") {
		t.Fatalf("error = %v", err)
	}
	if len(assemblies) != 1 || !reflect.DeepEqual(selectedQueueIDs, []int64{71, 72}) {
		t.Fatalf("assemblies = %d, queue IDs = %v", len(assemblies), selectedQueueIDs)
	}
}

func TestInspectAllRejectsInvalidEvidenceWithoutFailingCollection(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	other := fixture.radarr.records[0]
	other.ID = 72
	fixture.radarr.records = append(fixture.radarr.records, other)
	inspector := newTestInspector(t, fixture.dependencies(), func(
		observation casebuilder.Observation,
	) (casebuilder.Assembly, error) {
		if observation.Correlation.Radarr.ID == 71 {
			return casebuilder.Assembly{}, &casebuilder.InvalidEvidenceError{
				Err: errors.New("does not conform to the planner contract"),
			}
		}
		return casebuilder.Assembly{EncodedRequest: []byte("assembled")}, nil
	})

	result, err := inspector.InspectAll(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Assemblies) != 1 || !reflect.DeepEqual(result.Rejections, []Rejection{{
		QueueID: 71,
		Reason:  RejectionInvalidEvidence,
	}}) {
		t.Fatalf("result = %#v", result)
	}
}

func TestInspectAllReturnsNoCasesWithoutEligibleCandidates(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	fixture.radarr.records[0].Protocol = "usenet"
	inspector := newTestInspector(t, fixture.dependencies(), successfulTestAssembler)
	result, err := inspector.InspectAll(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	assemblies := result.Assemblies
	if len(assemblies) != 0 {
		t.Fatalf("assemblies = %d", len(assemblies))
	}
}

func TestInspectSkipsMovieSpecificReadsWithoutMovieID(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	fixture.radarr.records[0].MovieID = nil
	fixture.radarr.records[0].ErrorMessage = "A download client diagnostic"
	fixture.radarr.records[0].StatusMessages = nil
	var observed casebuilder.Observation
	inspector := newTestInspector(t, fixture.dependencies(), func(
		observation casebuilder.Observation,
	) (casebuilder.Assembly, error) {
		observed = observation
		return casebuilder.Assembly{}, nil
	})

	if _, err := inspector.Inspect(context.Background(), Selection{}); err != nil {
		t.Fatal(err)
	}
	if observed.Movie != nil || len(observed.History) != 0 || len(observed.ManualImports) != 0 {
		t.Fatalf("movie-specific evidence = %#v", observed)
	}
	if fixture.radarr.movieReads != 0 || fixture.radarr.historyReads != 0 ||
		fixture.radarr.manualImportReads != 0 {
		t.Fatalf("movie-specific reads = %d, %d, %d",
			fixture.radarr.movieReads,
			fixture.radarr.historyReads,
			fixture.radarr.manualImportReads,
		)
	}
	if observed.Correlation.Radarr.ErrorMessage != "A download client diagnostic" ||
		observed.Correlation.Radarr.StatusMessages != nil {
		t.Fatalf("queue evidence = %#v", observed.Correlation.Radarr)
	}
}

func TestInspectRejectsAmbiguousOrInvalidSelection(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		selection   Selection
		mutate      func(*inspectionTestFixture)
		want        string
		unavailable CandidateUnavailableReason
	}{
		{
			name: "no eligible candidates",
			mutate: func(fixture *inspectionTestFixture) {
				fixture.radarr.records[0].Protocol = "usenet"
			},
			want: "no completed unimported downloads",
		},
		{
			name: "ambiguous candidates",
			mutate: func(fixture *inspectionTestFixture) {
				other := fixture.radarr.records[0]
				other.ID++
				fixture.radarr.records = append(fixture.radarr.records, other)
			},
			want: "2 completed unimported downloads",
		},
		{
			name:        "missing requested candidate",
			selection:   Selection{QueueID: 999},
			mutate:      func(*inspectionTestFixture) {},
			want:        "record 999 was not found",
			unavailable: CandidateMissing,
		},
		{
			name:      "ineligible requested candidate",
			selection: Selection{QueueID: 71},
			mutate: func(fixture *inspectionTestFixture) {
				fixture.radarr.records[0].Protocol = "usenet"
			},
			want:        "record 71 is ineligible",
			unavailable: CandidateIneligible,
		},
		{
			name:      "negative requested candidate",
			selection: Selection{QueueID: -1},
			mutate:    func(*inspectionTestFixture) {},
			want:      "must not be negative",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := inspectionFixture()
			test.mutate(&fixture)
			inspector := newTestInspector(t, fixture.dependencies(), successfulTestAssembler)
			_, err := inspector.Inspect(context.Background(), test.selection)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
			if test.unavailable != "" {
				var unavailable *CandidateUnavailableError
				if !errors.As(err, &unavailable) || unavailable.Reason != test.unavailable {
					t.Fatalf("unavailable error = %#v, want %q", unavailable, test.unavailable)
				}
			}
		})
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
		{
			name: "assembler rejection",
			mutate: func(fixture *inspectionTestFixture) {
				fixture.assembleError = errors.New("infeasible")
			},
			want: "assemble repair case: infeasible",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := inspectionFixture()
			test.mutate(&fixture)
			inspector := newTestInspector(t, fixture.dependencies(), func(
				casebuilder.Observation,
			) (casebuilder.Assembly, error) {
				return casebuilder.Assembly{}, fixture.assembleError
			})
			_, err := inspector.Inspect(context.Background(), Selection{})
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestInspectHonorsCancellationBeforeReading(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	inspector := newTestInspector(t, fixture.dependencies(), successfulTestAssembler)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := inspector.Inspect(ctx, Selection{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v", err)
	}
	if fixture.radarr.queueReads != 0 {
		t.Fatal("Radarr queue was read after cancellation")
	}
}

func TestNewRejectsMissingCollectionTimeout(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	dependencies := fixture.dependencies()
	dependencies.CollectionTimeout = 0
	if _, err := newInspector(dependencies, successfulTestAssembler); err == nil ||
		!strings.Contains(err.Error(), "collection timeout") {
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
	var observed casebuilder.Observation
	inspector := newTestInspector(t, fixture.dependencies(), func(
		observation casebuilder.Observation,
	) (casebuilder.Assembly, error) {
		observed = observation
		return casebuilder.Assembly{}, nil
	})
	if _, err := inspector.Inspect(context.Background(), Selection{}); err != nil {
		t.Fatal(err)
	}
	if len(observed.Probes) != 3 ||
		observed.Probes[0].Outcome.Status != controller.MediaProbeFailed ||
		observed.Probes[1].Outcome.Status != controller.MediaProbeFailed ||
		observed.Probes[2].Outcome.Status != controller.MediaProbeNotCollected ||
		observed.Probes[2].Outcome.Reason != controller.MediaProbeNotCandidate {
		t.Fatalf("probe outcomes = %#v", observed.Probes)
	}
	if len(fixture.probes.targets) != 2 {
		t.Fatalf("worker probe targets = %#v", fixture.probes.targets)
	}
}

func TestInspectRetainsCollectionDeadlineAsIncompleteEvidence(t *testing.T) {
	t.Parallel()

	fixture := inspectionFixture()
	fixture.probes.waitForCancellation = true
	dependencies := fixture.dependencies()
	dependencies.CollectionTimeout = 20 * time.Millisecond
	var observed casebuilder.Observation
	inspector := newTestInspector(t, dependencies, func(
		observation casebuilder.Observation,
	) (casebuilder.Assembly, error) {
		observed = observation
		return casebuilder.Assembly{}, nil
	})
	if _, err := inspector.Inspect(context.Background(), Selection{}); err != nil {
		t.Fatal(err)
	}
	if len(observed.Probes) != 2 {
		t.Fatalf("probe outcomes = %#v", observed.Probes)
	}
	for _, probe := range observed.Probes {
		if probe.Outcome.Status != controller.MediaProbeNotCollected ||
			probe.Outcome.Reason != controller.MediaProbeCollectionLimit {
			t.Fatalf("probe outcome = %#v", probe)
		}
	}
	if len(fixture.probes.targets) != 1 {
		t.Fatalf("worker probe targets = %#v", fixture.probes.targets)
	}
}

type inspectionTestFixture struct {
	clock         *fakeClock
	radarr        *fakeRadarr
	transmission  *fakeTransmission
	files         *fakeFiles
	probes        *fakeProbes
	assembleError error
}

func inspectionFixture() inspectionTestFixture {
	record, torrent := eligibleDownload()
	first := inventoryFile("file:one", "CD1.mkv", 1_000, 10, 0)
	second := inventoryFile("file:two", "CD2.mkv", 2_000, 11, 1)
	return inspectionTestFixture{
		clock: &fakeClock{now: time.Date(2026, time.September, 7, 18, 0, 0, 0, time.UTC)},
		radarr: &fakeRadarr{
			records: []controller.RadarrQueueRecord{record},
			movie:   controller.RadarrMovie{ID: 42, TMDBID: 1234, Title: "Example Movie", Year: 2024},
			history: []controller.RadarrHistoryEvent{{ID: 501, MovieID: 42, DownloadID: record.DownloadID}},
			imports: []controller.RadarrManualImport{{Path: "/downloads/Example_Movie/CD1.mkv"}},
		},
		transmission: &fakeTransmission{torrent: torrent, found: true},
		files: &fakeFiles{inventory: controller.FileInventory{
			Files: []controller.InventoryFile{first, second},
			Paths: []controller.FilePathMapping{
				{FileID: first.ID, AbsolutePath: "/downloads/Example_Movie/CD1.mkv"},
				{FileID: second.ID, AbsolutePath: "/downloads/Example_Movie/CD2.mkv"},
			},
		}},
		probes: &fakeProbes{evidence: controller.ProbeEvidence{Format: controller.ProbeFormat{
			Names: []string{"matroska"},
		}}},
	}
}

func (fixture inspectionTestFixture) dependencies() Dependencies {
	return Dependencies{
		Clock: fixture.clock, Radarr: fixture.radarr, Downloads: fixture.transmission,
		Files: fixture.files, Probes: fixture.probes, CollectionTimeout: time.Minute,
	}
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

func newTestInspector(t *testing.T, dependencies Dependencies, assemble assembleFunc) *Inspector {
	t.Helper()
	inspector, err := newInspector(dependencies, assemble)
	if err != nil {
		t.Fatal(err)
	}
	return inspector
}

func successfulTestAssembler(casebuilder.Observation) (casebuilder.Assembly, error) {
	return casebuilder.Assembly{}, nil
}

type fakeClock struct {
	now time.Time
}

func (clock *fakeClock) Now() time.Time {
	return clock.now
}

type fakeRadarr struct {
	records           []controller.RadarrQueueRecord
	movie             controller.RadarrMovie
	history           []controller.RadarrHistoryEvent
	imports           []controller.RadarrManualImport
	manualImportQuery controller.RadarrManualImportQuery
	queueReads        int
	movieReads        int
	historyReads      int
	manualImportReads int
}

func (reader *fakeRadarr) ReadQueue(context.Context) ([]controller.RadarrQueueRecord, error) {
	reader.queueReads++
	return reader.records, nil
}

func (reader *fakeRadarr) ReadMovie(context.Context, int64) (controller.RadarrMovie, error) {
	reader.movieReads++
	return reader.movie, nil
}

func (reader *fakeRadarr) ReadHistory(
	context.Context,
	int64,
	string,
) ([]controller.RadarrHistoryEvent, error) {
	reader.historyReads++
	return reader.history, nil
}

func (reader *fakeRadarr) ReadManualImports(
	_ context.Context,
	query controller.RadarrManualImportQuery,
) ([]controller.RadarrManualImport, error) {
	reader.manualImportReads++
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

type fakeProbes struct {
	evidence            controller.ProbeEvidence
	outcome             controller.MediaProbeOutcome
	err                 error
	waitForCancellation bool
	targets             []controller.MediaProbeTarget
}

func (reader *fakeProbes) Probe(
	ctx context.Context,
	target controller.MediaProbeTarget,
) (controller.MediaProbeOutcome, error) {
	reader.targets = append(reader.targets, target)
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
	return controller.SuccessfulMediaProbe(reader.evidence), nil
}

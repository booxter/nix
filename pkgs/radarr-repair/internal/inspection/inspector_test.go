package inspection

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
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
		!reflect.DeepEqual(observed.Movie, fixture.radarr.movie) ||
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

func TestInspectRejectsAmbiguousOrInvalidSelection(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		selection Selection
		mutate    func(*inspectionTestFixture)
		want      string
	}{
		{
			name: "no eligible candidates",
			mutate: func(fixture *inspectionTestFixture) {
				fixture.radarr.records[0].Protocol = "usenet"
			},
			want: "no eligible repair candidates",
		},
		{
			name: "ambiguous candidates",
			mutate: func(fixture *inspectionTestFixture) {
				other := fixture.radarr.records[0]
				other.ID++
				fixture.radarr.records = append(fixture.radarr.records, other)
			},
			want: "2 eligible repair candidates",
		},
		{
			name:      "missing requested candidate",
			selection: Selection{QueueID: 999},
			mutate:    func(*inspectionTestFixture) {},
			want:      "record 999 was not found",
		},
		{
			name:      "ineligible requested candidate",
			selection: Selection{QueueID: 71},
			mutate: func(fixture *inspectionTestFixture) {
				fixture.radarr.records[0].Protocol = "usenet"
			},
			want: "record 71 is ineligible",
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
				fixture.transmission.torrent.Hash = "abcdef0123456789abcdef0123456789abcdef02"
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
		Clock: fixture.clock, Radarr: fixture.radarr, Transmission: fixture.transmission,
		Files: fixture.files, Probes: fixture.probes,
	}
}

func eligibleDownload() (controller.RadarrQueueRecord, controller.TransmissionTorrent) {
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
		OutputPath: "/downloads/Example_Movie",
	}
	torrent := controller.TransmissionTorrent{
		Hash: testDownloadHash, Name: "Example:Movie", Status: 6,
		PercentDone: 1, DownloadDirectory: "/downloads", TotalSizeBytes: 3_000,
		Files: []controller.TransmissionFile{
			{Index: 0, Name: "Example:Movie/CD1.mkv", LengthBytes: 1_000, BytesCompleted: 1_000, Wanted: true},
			{Index: 1, Name: "Example:Movie/CD2.mkv", LengthBytes: 2_000, BytesCompleted: 2_000, Wanted: true},
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
		TorrentFile: &controller.TorrentFileReference{
			Index: torrentIndex, LengthBytes: size, BytesCompleted: size, Wanted: true,
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
}

func (reader *fakeRadarr) ReadQueue(context.Context) ([]controller.RadarrQueueRecord, error) {
	reader.queueReads++
	return reader.records, nil
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
	torrent    controller.TransmissionTorrent
	found      bool
	downloadID string
}

func (reader *fakeTransmission) FindTorrent(
	_ context.Context,
	downloadID string,
) (controller.TransmissionTorrent, bool, error) {
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
	evidence controller.ProbeEvidence
	err      error
	targets  []controller.MediaProbeTarget
}

func (reader *fakeProbes) Probe(
	_ context.Context,
	target controller.MediaProbeTarget,
) (controller.ProbeEvidence, error) {
	reader.targets = append(reader.targets, target)
	return reader.evidence, reader.err
}

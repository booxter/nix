package casebuilder

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

const (
	testDownloadHash = "abcdef0123456789abcdef0123456789abcdef01"
	testFileOneID    = controller.FileID("file:1111111111111111111111111111111111111111111111111111111111111111")
	testFileTwoID    = controller.FileID("file:2222222222222222222222222222222222222222222222222222222222222222")
)

func TestAssembleProducesRedactedValidatedCase(t *testing.T) {
	t.Parallel()

	observation := testObservation()
	assembly, err := Assemble(observation)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := contracts.DecodeCase(assembly.EncodedRequest); err != nil {
		t.Fatalf("decode assembled case: %v", err)
	}
	if assembly.LocalSnapshot.CaseID != assembly.Request.CaseID {
		t.Fatalf("local case ID = %q, request case ID = %q", assembly.LocalSnapshot.CaseID, assembly.Request.CaseID)
	}
	if assembly.LocalSnapshot.Observation.Correlation.DownloadRoot != "/srv/downloads/Example.Movie.2024" {
		t.Fatal("local snapshot did not retain the download root")
	}
	for _, localOnly := range []string{
		testDownloadHash,
		"/srv/downloads",
		"/srv/downloads/Example.Movie.2024/CD1.mkv",
	} {
		if bytes.Contains(bytes.ToLower(assembly.EncodedRequest), []byte(strings.ToLower(localOnly))) {
			t.Fatalf("planner request contains local-only value %q", localOnly)
		}
	}

	want, err := os.ReadFile(filepath.Join("testdata", "repair-case.json"))
	if err != nil {
		t.Fatal(err)
	}
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, assembly.EncodedRequest, "", "  "); err != nil {
		t.Fatal(err)
	}
	pretty.WriteByte('\n')
	if !bytes.Equal(pretty.Bytes(), want) {
		t.Fatalf("assembled case differs from golden file:\n%s", pretty.Bytes())
	}
}

func TestAssembleCaseIdentityIgnoresObservationTime(t *testing.T) {
	t.Parallel()

	observation := testObservation()
	first, err := Assemble(observation)
	if err != nil {
		t.Fatal(err)
	}
	observation.ObservedAt = observation.ObservedAt.Add(time.Hour)
	second, err := Assemble(observation)
	if err != nil {
		t.Fatal(err)
	}
	if first.Request.CaseID != second.Request.CaseID {
		t.Fatalf("case ID changed from %q to %q", first.Request.CaseID, second.Request.CaseID)
	}
}

func TestAssembleRejectsInconsistentObservations(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*Observation)
		want   string
	}{
		{
			name: "missing probe",
			mutate: func(observation *Observation) {
				observation.Probes = observation.Probes[:1]
			},
			want: "has no successful probe",
		},
		{
			name: "extra probe",
			mutate: func(observation *Observation) {
				observation.Probes = append(observation.Probes, FileProbe{
					FileID: "file:3333333333333333333333333333333333333333333333333333333333333333",
				})
			},
			want: "does not exactly match",
		},
		{
			name: "duplicate inventory ID",
			mutate: func(observation *Observation) {
				observation.Inventory.Files[1].ID = testFileOneID
			},
			want: "duplicate file ID",
		},
		{
			name: "infeasible container",
			mutate: func(observation *Observation) {
				observation.Probes[1].Evidence.Format.Names = []string{"mov"}
			},
			want: "not eligible for deterministic joining",
		},
		{
			name: "history movie mismatch",
			mutate: func(observation *Observation) {
				observation.History[0].MovieID++
			},
			want: "refers to another movie",
		},
		{
			name: "unknown manual import path",
			mutate: func(observation *Observation) {
				observation.ManualImports[0].Path = "/srv/downloads/elsewhere/CD1.mkv"
			},
			want: "does not match the inventory",
		},
		{
			name: "manual import size mismatch",
			mutate: func(observation *Observation) {
				observation.ManualImports[0].SizeBytes++
			},
			want: "manual import size does not match",
		},
		{
			name: "incomplete stream disposition",
			mutate: func(observation *Observation) {
				observation.Probes[0].Evidence.Streams[0].Disposition.Forced = nil
			},
			want: "disposition is incomplete",
		},
		{
			name: "local value in retained text",
			mutate: func(observation *Observation) {
				observation.Movie.Title = "Example " + testDownloadHash
			},
			want: "raw download identifier",
		},
		{
			name: "local path in retained text",
			mutate: func(observation *Observation) {
				observation.Movie.Title = observation.Inventory.Paths[0].AbsolutePath
			},
			want: "contains a local path",
		},
		{
			name: "contract limit",
			mutate: func(observation *Observation) {
				observation.Movie.AlternateTitles = make([]string, 1_025)
				for index := range observation.Movie.AlternateTitles {
					observation.Movie.AlternateTitles[index] = "title " + strconv.Itoa(index)
				}
			},
			want: "invalid repair case",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			observation := testObservation()
			test.mutate(&observation)
			_, err := Assemble(observation)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func testObservation() Observation {
	observedAt := time.Date(2026, time.September, 7, 14, 0, 0, 0, time.FixedZone("EDT", -4*60*60))
	completedAt := observedAt.Add(-2 * time.Hour)
	movieID := int64(42)
	runtime := 120
	originalTitle := "Example Original"
	imdbID := "tt12345678"
	quality := "Bluray-1080p"
	releaseGroup := "GROUP"

	files := []controller.InventoryFile{
		testInventoryFile(testFileOneID, "CD1.mkv", 1_000, 0),
		testInventoryFile(testFileTwoID, "CD2.mkv", 2_000, 1),
	}
	paths := []controller.FilePathMapping{
		{FileID: testFileOneID, AbsolutePath: "/srv/downloads/Example.Movie.2024/CD1.mkv"},
		{FileID: testFileTwoID, AbsolutePath: "/srv/downloads/Example.Movie.2024/CD2.mkv"},
	}
	return Observation{
		ObservedAt: observedAt,
		Correlation: controller.DownloadCorrelation{
			DownloadRoot: "/srv/downloads/Example.Movie.2024",
			Radarr: controller.RadarrQueueRecord{
				ID:                    71,
				MovieID:               &movieID,
				Title:                 "Example.Movie.2024.1080p.BluRay-GROUP",
				Status:                "completed",
				TrackedDownloadStatus: "warning",
				TrackedDownloadState:  "importBlocked",
				StatusMessages: []controller.RadarrStatusMessage{{
					Title: "Import failed",
					Messages: []string{
						"File is suspected multi-part file, Radarr doesn't support this",
					},
				}},
				DownloadID:         strings.ToUpper(testDownloadHash),
				Protocol:           "torrent",
				OutputPath:         "/srv/downloads/Example.Movie.2024",
				SizeBytes:          3_000,
				SizeRemainingBytes: 0,
			},
			Transmission: controller.TransmissionTorrent{
				Hash:              testDownloadHash,
				Name:              "Example.Movie.2024",
				Status:            6,
				PercentDone:       1,
				LeftUntilDone:     0,
				Finished:          true,
				DownloadDirectory: "/srv/downloads",
				Labels:            []string{"radarr"},
				CompletedAt:       &completedAt,
				TotalSizeBytes:    3_000,
				Files: []controller.TransmissionFile{
					{Index: 0, Name: "Example.Movie.2024/CD1.mkv", LengthBytes: 1_000, BytesCompleted: 1_000, Wanted: true},
					{Index: 1, Name: "Example.Movie.2024/CD2.mkv", LengthBytes: 2_000, BytesCompleted: 2_000, Wanted: true},
				},
				TrackerHosts: []string{"tracker.example"},
			},
		},
		Movie: controller.RadarrMovie{
			ID:              movieID,
			TMDBID:          1234,
			IMDbID:          &imdbID,
			Title:           "Example Movie",
			OriginalTitle:   &originalTitle,
			AlternateTitles: []string{"Another Example"},
			Year:            2024,
			RuntimeMinutes:  &runtime,
		},
		History: []controller.RadarrHistoryEvent{{
			ID:          501,
			MovieID:     movieID,
			DownloadID:  strings.ToUpper(testDownloadHash),
			EventType:   "grabbed",
			OccurredAt:  observedAt.Add(-3 * time.Hour),
			SourceTitle: "Example.Movie.2024.1080p.BluRay-GROUP",
			Quality:     &quality,
			Languages:   []string{"English"},
		}},
		ManualImports: []controller.RadarrManualImport{
			{
				Path:         paths[0].AbsolutePath,
				RelativePath: "CD1.mkv",
				SizeBytes:    1_000,
				Quality:      &quality,
				Languages:    []string{"English"},
				ReleaseGroup: &releaseGroup,
				Rejections: []controller.RadarrManualImportRejection{{
					Type: "permanent", Reason: "File is suspected multi-part file, Radarr doesn't support this",
				}},
			},
			{
				Path:         paths[1].AbsolutePath,
				RelativePath: "CD2.mkv",
				SizeBytes:    2_000,
				Quality:      &quality,
				Languages:    []string{"English"},
				ReleaseGroup: &releaseGroup,
				Rejections: []controller.RadarrManualImportRejection{{
					Type: "permanent", Reason: "File is suspected multi-part file, Radarr doesn't support this",
				}},
			},
		},
		Inventory: controller.FileInventory{Files: files, Paths: paths},
		Probes: []FileProbe{
			{FileID: testFileOneID, Evidence: testProbe(1_000, 3_600_000)},
			{FileID: testFileTwoID, Evidence: testProbe(2_000, 3_600_000)},
		},
	}
}

func testInventoryFile(id controller.FileID, name string, size int64, index int) controller.InventoryFile {
	return controller.InventoryFile{
		ID:             id,
		PathComponents: []string{name},
		Fingerprint: controller.FileFingerprint{
			Device: 1, Inode: uint64(index + 10), SizeBytes: size, MTimeNS: 1_789_000_000_000_000_000,
		},
		TorrentFile: &controller.TorrentFileReference{
			Index: index, LengthBytes: size, BytesCompleted: size, Wanted: true,
		},
	}
}

func testProbe(size int64, duration int64) controller.ProbeEvidence {
	kind := controller.ProbeStreamVideo
	codec := "h264"
	profile := "High"
	pixelFormat := "yuv420p"
	width := int64(1920)
	height := int64(1080)
	start := int64(0)
	bitRate := int64(8_500_000)
	defaultDisposition := true
	falseValue := false
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names: []string{"matroska", "webm"}, DurationMS: &duration,
			SizeBytes: &size, BitRateBPS: &bitRate,
		},
		Streams: []controller.ProbeStream{{
			Index: 0, Kind: &kind, CodecName: &codec, Profile: &profile,
			Width: &width, Height: &height, PixelFormat: &pixelFormat,
			AverageRate: &controller.Rational{Numerator: 24_000, Denominator: 1_001},
			TimeBase:    &controller.Rational{Numerator: 1, Denominator: 1_000},
			StartTimeMS: &start, DurationMS: &duration, BitRateBPS: &bitRate,
			Disposition: &controller.ProbeDisposition{
				Default: &defaultDisposition, Forced: &falseValue,
				HearingImpaired: &falseValue, VisualImpaired: &falseValue,
			},
		}},
	}
}

package casestore

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
)

func TestStoreJoinedFileImportLifecycle(t *testing.T) {
	t.Parallel()

	store, authorized, publishedAt := publishedJoinForImport(t)
	scan := testJoinScanRequest()
	preparedAt := publishedAt.Add(time.Minute)
	prepared, changed, err := store.PrepareJoinScan(authorized.CaseID, scan, preparedAt)
	if err != nil || !changed || prepared.State != JoinScanPrepared || prepared.Scan == nil ||
		prepared.Scan.CommandID != nil || !prepared.Scan.PreparedAt.Equal(preparedAt) {
		t.Fatalf("prepare scan: changed = %t, record = %#v, error = %v", changed, prepared, err)
	}
	repeated, changed, err := store.PrepareJoinScan(
		authorized.CaseID,
		scan,
		preparedAt.Add(time.Minute),
	)
	if err != nil || changed || !reflect.DeepEqual(repeated, prepared) {
		t.Fatalf("repeat prepare: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}
	differentScan := scan
	differentScan.Path = "/downloads/Movie.Release/other.mkv"
	if _, _, err := store.PrepareJoinScan(
		authorized.CaseID,
		differentScan,
		preparedAt.Add(time.Minute),
	); err == nil {
		t.Fatal("join was rebound to a different Radarr scan")
	}

	requestedAt := preparedAt.Add(time.Minute)
	requested, changed, err := store.MarkJoinScanRequested(
		authorized.CaseID,
		92,
		requestedAt,
	)
	if err != nil || !changed || requested.State != JoinScanRequested ||
		requested.Scan == nil || requested.Scan.CommandID == nil || *requested.Scan.CommandID != 92 {
		t.Fatalf("request scan: changed = %t, record = %#v, error = %v", changed, requested, err)
	}
	repeated, changed, err = store.MarkJoinScanRequested(
		authorized.CaseID,
		92,
		requestedAt.Add(time.Minute),
	)
	if err != nil || changed || !reflect.DeepEqual(repeated, requested) {
		t.Fatalf("repeat request: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}
	if _, _, err := store.MarkJoinScanRequested(
		authorized.CaseID,
		93,
		requestedAt.Add(time.Minute),
	); err == nil {
		t.Fatal("scan was rebound to a different Radarr command")
	}

	importedEvidence := testJoinedFileImport(scan, preparedAt.Add(2*time.Minute))
	imported, changed, err := store.MarkJoinImported(
		authorized.CaseID,
		importedEvidence,
		preparedAt.Add(3*time.Minute),
	)
	if err != nil || !changed || imported.State != JoinImported || imported.Confirmation == nil ||
		imported.Confirmation.HistoryID != importedEvidence.HistoryID {
		t.Fatalf("confirm import: changed = %t, record = %#v, error = %v", changed, imported, err)
	}
	repeated, changed, err = store.MarkJoinImported(
		authorized.CaseID,
		importedEvidence,
		preparedAt.Add(4*time.Minute),
	)
	if err != nil || changed || !reflect.DeepEqual(repeated, imported) {
		t.Fatalf("repeat confirmation: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}

	stored, found, err := store.GetJoinExecution(authorized.CaseID)
	if err != nil || !found || !reflect.DeepEqual(stored, imported) {
		t.Fatalf("stored import: found = %t, record = %#v, error = %v", found, stored, err)
	}
}

func TestStoreJoinedFileImportRecoversWithoutCommandID(t *testing.T) {
	t.Parallel()

	store, authorized, publishedAt := publishedJoinForImport(t)
	scan := testJoinScanRequest()
	preparedAt := publishedAt.Add(time.Minute)
	if _, _, err := store.PrepareJoinScan(authorized.CaseID, scan, preparedAt); err != nil {
		t.Fatal(err)
	}
	imported, changed, err := store.MarkJoinImported(
		authorized.CaseID,
		testJoinedFileImport(scan, preparedAt.Add(time.Minute)),
		preparedAt.Add(2*time.Minute),
	)
	if err != nil || !changed || imported.State != JoinImported ||
		imported.Scan == nil || imported.Scan.CommandID != nil {
		t.Fatalf("recovered import: changed = %t, record = %#v, error = %v", changed, imported, err)
	}
}

func TestStoreJoinedFileImportRequiresExactEvidence(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		change func(*controller.RadarrImportedFile, time.Time)
	}{
		{name: "movie", change: func(imported *controller.RadarrImportedFile, _ time.Time) {
			imported.MovieID++
		}},
		{name: "download", change: func(imported *controller.RadarrImportedFile, _ time.Time) {
			imported.DownloadID = "different-download"
		}},
		{name: "path", change: func(imported *controller.RadarrImportedFile, _ time.Time) {
			imported.DroppedPath = "/downloads/Movie.Release/other.mkv"
		}},
		{name: "old event", change: func(imported *controller.RadarrImportedFile, _ time.Time) {
			imported.HistoryID = 100
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			store, authorized, publishedAt := publishedJoinForImport(t)
			scan := testJoinScanRequest()
			preparedAt := publishedAt.Add(time.Minute)
			if _, _, err := store.PrepareJoinScan(authorized.CaseID, scan, preparedAt); err != nil {
				t.Fatal(err)
			}
			imported := testJoinedFileImport(scan, preparedAt.Add(time.Minute))
			test.change(&imported, preparedAt)
			if _, changed, err := store.MarkJoinImported(
				authorized.CaseID,
				imported,
				preparedAt.Add(2*time.Minute),
			); err == nil || changed {
				t.Fatalf("changed = %t, error = %v", changed, err)
			}
		})
	}
}

func TestStoreJoinedFileImportFailureIsTerminal(t *testing.T) {
	t.Parallel()

	store, authorized, publishedAt := publishedJoinForImport(t)
	scan := testJoinScanRequest()
	preparedAt := publishedAt.Add(time.Minute)
	if _, _, err := store.PrepareJoinScan(authorized.CaseID, scan, preparedAt); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.MarkJoinImportFailed(
		authorized.CaseID,
		preparedAt.Add(time.Minute),
	); err == nil {
		t.Fatal("scan without a known command was marked failed")
	}
	if _, _, err := store.MarkJoinScanRequested(
		authorized.CaseID,
		92,
		preparedAt.Add(time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	failed, changed, err := store.MarkJoinImportFailed(
		authorized.CaseID,
		preparedAt.Add(2*time.Minute),
	)
	if err != nil || !changed || failed.State != JoinImportFailed {
		t.Fatalf("failed import: changed = %t, record = %#v, error = %v", changed, failed, err)
	}
	repeated, changed, err := store.MarkJoinImportFailed(
		authorized.CaseID,
		preparedAt.Add(3*time.Minute),
	)
	if err != nil || changed || !reflect.DeepEqual(repeated, failed) {
		t.Fatalf("repeat failure: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}
	if _, _, err := store.MarkJoinImported(
		authorized.CaseID,
		testJoinedFileImport(scan, preparedAt.Add(time.Minute)),
		preparedAt.Add(3*time.Minute),
	); err == nil {
		t.Fatal("failed import was changed to imported")
	}
}

func TestStoreJoinedFileScanRequiresPublishedMatchingCase(t *testing.T) {
	t.Parallel()

	store, authorized := newJoinExecutionStore(t)
	if _, _, err := store.PrepareJoin(
		authorized,
		time.Date(2026, time.September, 13, 18, 0, 0, 0, time.UTC),
	); err != nil {
		t.Fatal(err)
	}
	if _, changed, err := store.PrepareJoinScan(
		authorized.CaseID,
		testJoinScanRequest(),
		time.Date(2026, time.September, 13, 19, 0, 0, 0, time.UTC),
	); err == nil || changed {
		t.Fatalf("unpublished scan: changed = %t, error = %v", changed, err)
	}

	base := testJoinScanRequest()
	requests := []JoinScanRequest{
		{Path: "/downloads/Movie.Release/radarr-repair-join.mkv", MovieID: 43, DownloadID: base.DownloadID},
		{Path: "/downloads/Movie.Release/radarr-repair-join.mkv", MovieID: 42, DownloadID: "different-download"},
		{Path: "relative.mkv", MovieID: 42, DownloadID: base.DownloadID},
	}
	for _, request := range requests {
		candidate, candidateAuthorization, candidatePublishedAt := publishedJoinForImport(t)
		if _, changed, err := candidate.PrepareJoinScan(
			candidateAuthorization.CaseID,
			request,
			candidatePublishedAt.Add(time.Minute),
		); err == nil || changed {
			t.Fatalf("invalid scan %#v: changed = %t, error = %v", request, changed, err)
		}
	}
}

func TestDecodeJoinExecutionRejectsInvalidScanState(t *testing.T) {
	t.Parallel()

	_, _, _, published := publishedJoinRecord(t)
	published.State = JoinScanRequested
	data, err := json.Marshal(published)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeJoinExecution(data); err == nil {
		t.Fatal("requested scan without bound request was accepted")
	}
}

func publishedJoinForImport(
	t *testing.T,
) (*Store, decisionpolicy.AuthorizedJoin, time.Time) {
	t.Helper()
	store, authorized, publishedAt, _ := publishedJoinRecord(t)
	return store, authorized, publishedAt
}

func publishedJoinRecord(
	t *testing.T,
) (*Store, decisionpolicy.AuthorizedJoin, time.Time, JoinExecution) {
	t.Helper()
	store, authorized := newJoinExecutionStore(t)
	preparedAt := time.Date(2026, time.September, 13, 18, 0, 0, 0, time.UTC)
	prepared, _, err := store.PrepareJoin(authorized, preparedAt)
	if err != nil {
		t.Fatal(err)
	}
	request, response := successfulJoinStage(prepared, "request:stage:scan")
	if _, _, err := store.RecordJoinStage(
		authorized,
		request,
		response,
		preparedAt.Add(time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	publishedAt := preparedAt.Add(2 * time.Minute)
	published, _, err := store.RecordJoinPublish(
		authorized.CaseID,
		publishSuccess("request:publish:scan"),
		publishedAt,
	)
	if err != nil {
		t.Fatal(err)
	}
	return store, authorized, publishedAt, published
}

func testJoinScanRequest() JoinScanRequest {
	return JoinScanRequest{
		Path:            "/downloads/Movie.Release/radarr-repair-join.mkv",
		MovieID:         42,
		DownloadID:      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		HistoryIDBefore: 100,
	}
}

func testJoinedFileImport(
	scan JoinScanRequest,
	occurredAt time.Time,
) controller.RadarrImportedFile {
	return controller.RadarrImportedFile{
		HistoryID: 101, MovieFileID: 102, MovieID: scan.MovieID,
		DownloadID: scan.DownloadID, OccurredAt: occurredAt,
		DroppedPath: scan.Path, ImportedPath: "/library/Movie (2026)/Movie.mkv",
	}
}

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
	importRequest := testJoinImportRequest()
	preparedAt := publishedAt.Add(time.Minute)
	prepared, changed, err := store.PrepareJoinImport(authorized.CaseID, importRequest, preparedAt)
	if err != nil || !changed || prepared.State != JoinImportPrepared || prepared.Import == nil ||
		prepared.Import.CommandID != nil || !prepared.Import.PreparedAt.Equal(preparedAt) {
		t.Fatalf("prepare import: changed = %t, record = %#v, error = %v", changed, prepared, err)
	}
	repeated, changed, err := store.PrepareJoinImport(
		authorized.CaseID,
		importRequest,
		preparedAt.Add(time.Minute),
	)
	if err != nil || changed || !reflect.DeepEqual(repeated, prepared) {
		t.Fatalf("repeat prepare: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}
	differentImport := importRequest
	differentImport.Command.File.Path = "/downloads/Movie.Release/other.mkv"
	if _, _, err := store.PrepareJoinImport(
		authorized.CaseID,
		differentImport,
		preparedAt.Add(time.Minute),
	); err == nil {
		t.Fatal("join was rebound to a different Radarr import")
	}

	requestedAt := preparedAt.Add(time.Minute)
	requested, changed, err := store.MarkJoinImportRequested(
		authorized.CaseID,
		92,
		requestedAt,
	)
	if err != nil || !changed || requested.State != JoinImportRequested ||
		requested.Import == nil || requested.Import.CommandID == nil || *requested.Import.CommandID != 92 {
		t.Fatalf("request import: changed = %t, record = %#v, error = %v", changed, requested, err)
	}
	repeated, changed, err = store.MarkJoinImportRequested(
		authorized.CaseID,
		92,
		requestedAt.Add(time.Minute),
	)
	if err != nil || changed || !reflect.DeepEqual(repeated, requested) {
		t.Fatalf("repeat request: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}
	if _, _, err := store.MarkJoinImportRequested(
		authorized.CaseID,
		93,
		requestedAt.Add(time.Minute),
	); err == nil {
		t.Fatal("import was rebound to a different Radarr command")
	}

	importedEvidence := testJoinedFileImport(importRequest, preparedAt.Add(2*time.Minute))
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
	importRequest := testJoinImportRequest()
	preparedAt := publishedAt.Add(time.Minute)
	if _, _, err := store.PrepareJoinImport(authorized.CaseID, importRequest, preparedAt); err != nil {
		t.Fatal(err)
	}
	imported, changed, err := store.MarkJoinImported(
		authorized.CaseID,
		testJoinedFileImport(importRequest, preparedAt.Add(time.Minute)),
		preparedAt.Add(2*time.Minute),
	)
	if err != nil || !changed || imported.State != JoinImported ||
		imported.Import == nil || imported.Import.CommandID != nil {
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
			importRequest := testJoinImportRequest()
			preparedAt := publishedAt.Add(time.Minute)
			if _, _, err := store.PrepareJoinImport(authorized.CaseID, importRequest, preparedAt); err != nil {
				t.Fatal(err)
			}
			imported := testJoinedFileImport(importRequest, preparedAt.Add(time.Minute))
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
	importRequest := testJoinImportRequest()
	preparedAt := publishedAt.Add(time.Minute)
	if _, _, err := store.PrepareJoinImport(authorized.CaseID, importRequest, preparedAt); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.MarkJoinImportFailed(
		authorized.CaseID,
		preparedAt.Add(time.Minute),
	); err == nil {
		t.Fatal("import without a known command was marked failed")
	}
	if _, _, err := store.MarkJoinImportRequested(
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
		testJoinedFileImport(importRequest, preparedAt.Add(time.Minute)),
		preparedAt.Add(3*time.Minute),
	); err == nil {
		t.Fatal("failed import was changed to imported")
	}
}

func TestStoreJoinedFileImportRequiresPublishedMatchingCase(t *testing.T) {
	t.Parallel()

	store, authorized := newJoinExecutionStore(t)
	if _, _, err := store.PrepareJoin(
		authorized,
		time.Date(2026, time.September, 13, 18, 0, 0, 0, time.UTC),
	); err != nil {
		t.Fatal(err)
	}
	if _, changed, err := store.PrepareJoinImport(
		authorized.CaseID,
		testJoinImportRequest(),
		time.Date(2026, time.September, 13, 19, 0, 0, 0, time.UTC),
	); err == nil || changed {
		t.Fatalf("unpublished import: changed = %t, error = %v", changed, err)
	}

	wrongMovie := testJoinImportRequest()
	wrongMovie.Command.File.MovieID++
	wrongDownload := testJoinImportRequest()
	wrongDownload.Command.File.DownloadID = "different-download"
	badPath := testJoinImportRequest()
	badPath.Command.File.Path = "relative.mkv"
	requests := []JoinImportRequest{wrongMovie, wrongDownload, badPath}
	for _, request := range requests {
		candidate, candidateAuthorization, candidatePublishedAt := publishedJoinForImport(t)
		if _, changed, err := candidate.PrepareJoinImport(
			candidateAuthorization.CaseID,
			request,
			candidatePublishedAt.Add(time.Minute),
		); err == nil || changed {
			t.Fatalf("invalid import %#v: changed = %t, error = %v", request, changed, err)
		}
	}
}

func TestDecodeJoinExecutionRejectsInvalidImportState(t *testing.T) {
	t.Parallel()

	_, _, _, published := publishedJoinRecord(t)
	published.State = JoinImportRequested
	data, err := json.Marshal(published)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeJoinExecution(data); err == nil {
		t.Fatal("requested import without bound request was accepted")
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
	request, response := successfulJoinStage(prepared, "request:stage:import")
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
		publishSuccess("request:publish:import"),
		publishedAt,
	)
	if err != nil {
		t.Fatal(err)
	}
	return store, authorized, publishedAt, published
}

func testJoinImportRequest() JoinImportRequest {
	return JoinImportRequest{
		Command:         testJoinedFileImportCommand(),
		HistoryIDBefore: 100,
	}
}

func testJoinedFileImportCommand() controller.RadarrManualImportCommand {
	return controller.RadarrManualImportCommand{
		ImportMode: controller.RadarrImportModeCopy,
		File: controller.RadarrManualImportCommandFile{
			Path: "/downloads/Movie.Release/radarr-repair-join.mkv",
			Quality: controller.RadarrQualityModel{Quality: controller.RadarrQuality{
				ID: 7, Name: "Bluray-1080p", Source: "bluray",
				Resolution: 1080, Modifier: "none",
			}},
			Languages: []controller.RadarrLanguage{{ID: 1, Name: "English"}},
			MovieID:   42, DownloadID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		},
	}
}

func testJoinedFileImport(
	importRequest JoinImportRequest,
	occurredAt time.Time,
) controller.RadarrImportedFile {
	return controller.RadarrImportedFile{
		HistoryID: 101, MovieFileID: 102, MovieID: importRequest.Command.File.MovieID,
		DownloadID: importRequest.Command.File.DownloadID, OccurredAt: occurredAt,
		DroppedPath:  importRequest.Command.File.Path,
		ImportedPath: "/library/Movie (2026)/Movie.mkv",
	}
}

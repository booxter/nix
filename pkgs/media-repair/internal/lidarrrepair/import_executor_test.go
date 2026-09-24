package lidarrrepair

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
	"golift.io/starr"
)

func TestImportExecutorConfirmsEverySelectedTrack(t *testing.T) {
	t.Parallel()
	authorized := testAuthorizedImport()
	now := time.Date(2026, 9, 22, 12, 0, 0, 0, time.UTC)
	client := &fakeImportClient{
		command: servarr.Command{ID: 81, Name: "ManualImport", Status: servarr.CommandQueued},
		commands: []servarr.Command{{
			ID: 81, Name: "ManualImport", Status: servarr.CommandCompleted,
		}},
		history: [][]lidarr.ImportedTrack{
			{},
			{testImportedTrack(authorized.Tracks[0], now, 91)},
			{
				testImportedTrack(authorized.Tracks[0], now, 91),
				testImportedTrack(authorized.Tracks[1], now, 92),
			},
		},
	}
	store := &fakeImportStore{}
	waiter := &fakeImportWaiter{}
	executor, err := NewImportExecutor(ImportExecutorDependencies{
		Lidarr: client, Store: store, Clock: importFixedClock{now: now},
		Waiter: waiter, PollInterval: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}

	execution, err := executor.Execute(context.Background(), authorized)
	if err != nil {
		t.Fatal(err)
	}
	if execution.State != Imported || len(execution.Confirmations) != 2 ||
		client.requests != 1 || client.commandReads != 1 || client.historyReads != 3 ||
		waiter.waits != 1 {
		t.Fatalf(
			"execution=%#v requests=%d commands=%d history=%d waits=%d",
			execution, client.requests, client.commandReads, client.historyReads, waiter.waits,
		)
	}
	if len(client.requested.Files) != 2 || client.requested.Files[0].TrackID != 11 ||
		client.requested.Files[1].TrackID != 12 || client.requested.Files[0].AlbumReleaseID != 7 ||
		client.requested.Files[0].DownloadID != "" || client.requested.Files[1].DownloadID != "" {
		t.Fatalf("request = %#v", client.requested)
	}
}

func TestImportExecutorNeverRepeatsUncertainSubmission(t *testing.T) {
	t.Parallel()
	authorized := testAuthorizedImport()
	now := time.Date(2026, 9, 22, 12, 0, 0, 0, time.UTC)
	client := &fakeImportClient{requestErr: errors.New("response lost")}
	store := &fakeImportStore{}
	executor, err := NewImportExecutor(ImportExecutorDependencies{
		Lidarr: client, Store: store, Clock: importFixedClock{now: now},
		Waiter: &fakeImportWaiter{}, PollInterval: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}

	for attempt := 0; attempt < 2; attempt++ {
		execution, executeErr := executor.Execute(context.Background(), authorized)
		var uncertain *servarr.SubmissionUncertainError
		if !errors.As(executeErr, &uncertain) || execution.State != ImportPrepared {
			t.Fatalf("execution = %#v, error = %v", execution, executeErr)
		}
	}
	if client.requests != 1 {
		t.Fatalf("manual-import requests = %d", client.requests)
	}
}

func TestImportExecutorFailsWhenCompletedCommandHasNoImportHistory(t *testing.T) {
	t.Parallel()
	authorized := testAuthorizedImport()
	now := time.Date(2026, 9, 22, 12, 0, 0, 0, time.UTC)
	client := &fakeImportClient{
		command: servarr.Command{ID: 81, Name: "ManualImport", Status: servarr.CommandQueued},
		commands: []servarr.Command{{
			ID: 81, Name: "ManualImport", Status: servarr.CommandCompleted,
		}},
	}
	store := &fakeImportStore{}
	waiter := &fakeImportWaiter{}
	executor, err := NewImportExecutor(ImportExecutorDependencies{
		Lidarr: client, Store: store, Clock: importFixedClock{now: now},
		Waiter: waiter, PollInterval: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}

	execution, err := executor.Execute(context.Background(), authorized)
	if err != nil {
		t.Fatal(err)
	}
	if execution.State != ImportFailed || client.requests != 1 ||
		client.commandReads <= 1 || waiter.waits <= 0 {
		t.Fatalf(
			"execution=%#v requests=%d commands=%d waits=%d",
			execution, client.requests, client.commandReads, waiter.waits,
		)
	}
}

func testAuthorizedImport() AuthorizedImport {
	quality := &starr.Quality{Quality: &starr.BaseQuality{ID: 6, Name: "FLAC"}}
	return AuthorizedImport{
		CaseID:       "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		CapabilityID: "capability:import_missing_tracks:7", QueueID: 1,
		ArtistID: 2, AlbumID: 3, ReleaseID: 7,
		Tracks: []AuthorizedTrack{
			{
				ArtifactID: "artifact:one", ArtifactFingerprint: "sha256:one",
				TrackID: 11, Path: "/downloads/staged/01.flac", Quality: quality,
				DownloadID: "download",
			},
			{
				ArtifactID: "artifact:two", ArtifactFingerprint: "sha256:two",
				TrackID: 12, Path: "/downloads/staged/02.flac", Quality: quality,
				DownloadID: "download",
			},
		},
	}
}

func testImportedTrack(track AuthorizedTrack, at time.Time, historyID int64) lidarr.ImportedTrack {
	return lidarr.ImportedTrack{
		HistoryID: historyID, AlbumID: 3, ArtistID: 2, TrackID: track.TrackID,
		DroppedPath:  track.Path,
		ImportedPath: "/music/Artist/Album/" + track.ArtifactID + ".flac", OccurredAt: at,
	}
}

type importFixedClock struct{ now time.Time }

func (clock importFixedClock) Now() time.Time { return clock.now }

type fakeImportWaiter struct{ waits int }

func (waiter *fakeImportWaiter) Wait(context.Context, time.Duration) error {
	waiter.waits++
	return nil
}

type fakeImportClient struct {
	command      servarr.Command
	requestErr   error
	requested    lidarr.ManualImportCommand
	requests     int
	commands     []servarr.Command
	commandReads int
	history      [][]lidarr.ImportedTrack
	historyReads int
}

func (client *fakeImportClient) RequestManualImport(
	_ context.Context,
	command lidarr.ManualImportCommand,
) (servarr.Command, error) {
	client.requests++
	client.requested = command
	return client.command, client.requestErr
}

func (client *fakeImportClient) ReadManualImportCommand(
	context.Context,
	int64,
) (servarr.Command, error) {
	index := client.commandReads
	client.commandReads++
	if len(client.commands) == 0 {
		return servarr.Command{}, errors.New("unexpected command read")
	}
	if index >= len(client.commands) {
		index = len(client.commands) - 1
	}
	return client.commands[index], nil
}

func (client *fakeImportClient) ReadImportedTracks(
	context.Context,
	int64,
	string,
) ([]lidarr.ImportedTrack, error) {
	index := client.historyReads
	client.historyReads++
	if len(client.history) == 0 {
		return []lidarr.ImportedTrack{}, nil
	}
	if index >= len(client.history) {
		index = len(client.history) - 1
	}
	return append([]lidarr.ImportedTrack(nil), client.history[index]...), nil
}

type fakeImportStore struct {
	found     bool
	execution ImportExecution
}

func (store *fakeImportStore) PrepareImport(
	authorized AuthorizedImport,
	historyIDBefore int64,
	at time.Time,
) (ImportExecution, bool, error) {
	if store.found {
		return store.execution, false, nil
	}
	store.found = true
	store.execution = executionFromAuthorization(authorized, historyIDBefore, at)
	return store.execution, true, nil
}

func (store *fakeImportStore) MarkImportRequested(
	_ string,
	commandID int64,
	at time.Time,
) (ImportExecution, bool, error) {
	store.execution.State = ImportRequested
	store.execution.CommandID = &commandID
	store.execution.UpdatedAt = at
	return store.execution, true, nil
}

func (store *fakeImportStore) MarkImported(
	_ string,
	confirmations []lidarr.ImportedTrack,
	at time.Time,
) (ImportExecution, bool, error) {
	store.execution.State = Imported
	store.execution.Confirmations = append([]lidarr.ImportedTrack(nil), confirmations...)
	store.execution.UpdatedAt = at
	return store.execution, true, nil
}

func (store *fakeImportStore) MarkImportFailed(
	_ string,
	at time.Time,
) (ImportExecution, bool, error) {
	store.execution.State = ImportFailed
	store.execution.UpdatedAt = at
	return store.execution, true, nil
}

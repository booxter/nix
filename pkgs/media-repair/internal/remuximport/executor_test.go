package remuximport

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

const testCaseID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func TestPreparedRemuxImportRecoversFromRadarrHistoryWithoutResubmission(t *testing.T) {
	t.Parallel()
	for _, confirmed := range []bool{false, true} {
		t.Run(map[bool]string{false: "unconfirmed", true: "confirmed"}[confirmed], func(t *testing.T) {
			t.Parallel()
			store := &fakeStore{execution: casestore.RemuxExecution{
				Authorization: decisionpolicy.AuthorizedRemux{CaseID: testCaseID},
				State:         casestore.RemuxImportPrepared,
				Import: &casestore.JoinImport{
					Command: controller.RadarrManualImportCommand{
						File: controller.RadarrManualImportCommandFile{
							MovieID: 42, DownloadID: "download-1", Path: "/downloads/film.mkv",
						},
					},
					HistoryIDBefore: 100,
				},
			}}
			client := &fakeRadarr{}
			if confirmed {
				client.imports = []controller.RadarrImportedFile{{
					HistoryID: 101, MovieFileID: 102, MovieID: 42,
					DownloadID: "download-1", DroppedPath: "/downloads/film.mkv",
					ImportedPath: "/library/film.mkv", OccurredAt: time.Now().UTC(),
				}}
			}
			executor, err := New(Dependencies{
				Radarr: client, Store: store, Paths: fakePaths{},
				Clock: fakeClock{}, Waiter: fakeWaiter{}, PollInterval: time.Second,
			})
			if err != nil {
				t.Fatal(err)
			}
			execution, err := executor.Execute(context.Background(), testCaseID)
			if client.requests != 0 {
				t.Fatalf("submitted a duplicate Radarr import: %d", client.requests)
			}
			if confirmed {
				if err != nil || execution.State != casestore.RemuxImported || store.confirmations != 1 {
					t.Fatalf("confirmed: state = %q, confirmations = %d, error = %v", execution.State, store.confirmations, err)
				}
			} else {
				var uncertain *servarr.SubmissionUncertainError
				if !errors.As(err, &uncertain) || execution.State != casestore.RemuxImportPrepared {
					t.Fatalf("uncertain: state = %q, error = %v", execution.State, err)
				}
			}
		})
	}
}

type fakeStore struct {
	execution     casestore.RemuxExecution
	confirmations int
}

func (store *fakeStore) Get(string) (casestore.CaseRecord, bool, error) {
	return casestore.CaseRecord{}, false, nil
}

func (store *fakeStore) GetRemuxExecution(string) (casestore.RemuxExecution, bool, error) {
	return store.execution, true, nil
}

func (store *fakeStore) PrepareRemuxImport(
	string, casestore.JoinImportRequest, time.Time,
) (casestore.RemuxExecution, bool, error) {
	return casestore.RemuxExecution{}, false, errors.New("unexpected submission")
}

func (store *fakeStore) MarkRemuxImportRequested(
	string, int64, time.Time,
) (casestore.RemuxExecution, bool, error) {
	return casestore.RemuxExecution{}, false, errors.New("unexpected submission")
}

func (store *fakeStore) MarkRemuxImported(
	_ string, _ controller.RadarrImportedFile, _ time.Time,
) (casestore.RemuxExecution, bool, error) {
	store.confirmations++
	store.execution.State = casestore.RemuxImported
	return store.execution, true, nil
}

func (store *fakeStore) MarkRemuxImportFailed(
	string, time.Time,
) (casestore.RemuxExecution, bool, error) {
	return casestore.RemuxExecution{}, false, errors.New("unexpected failure")
}

type fakeRadarr struct {
	imports  []controller.RadarrImportedFile
	requests int
}

func (client *fakeRadarr) RequestManualImport(
	context.Context, controller.RadarrManualImportCommand,
) (servarr.Command, error) {
	client.requests++
	return servarr.Command{}, nil
}

func (client *fakeRadarr) ReadManualImportCommand(context.Context, int64) (servarr.Command, error) {
	return servarr.Command{}, errors.New("unexpected command read")
}

func (client *fakeRadarr) ReadImportedFiles(
	context.Context, int64, string,
) ([]controller.RadarrImportedFile, error) {
	return client.imports, nil
}

type fakePaths struct{}

func (fakePaths) ResolvePublishedPath(string, []string) (string, error) {
	return "", errors.New("unexpected path resolution")
}

type fakeClock struct{}

func (fakeClock) Now() time.Time { return time.Now().UTC() }

type fakeWaiter struct{}

func (fakeWaiter) Wait(context.Context, time.Duration) error {
	return errors.New("unexpected wait")
}

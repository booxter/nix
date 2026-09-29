package queueaction

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
)

func TestRequestRoundTripAndProcessing(t *testing.T) {
	t.Parallel()
	requestsPath := filepath.Join(t.TempDir(), "requests")
	if err := os.Mkdir(requestsPath, 0o750); err != nil {
		t.Fatal(err)
	}
	requests, err := NewStore(requestsPath, ServiceRadarr)
	if err != nil {
		t.Fatal(err)
	}
	createdAt := time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC)
	request, err := NewRequest(
		ServiceRadarr,
		"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Identity(queuefinalize.Entry{
			QueueID: 7, DownloadID: "download", SubjectID: 42,
			Status: "completed", TrackedDownloadStatus: "warning",
		}),
		createdAt,
	)
	if err != nil {
		t.Fatal(err)
	}
	if created, err := requests.Submit(request); err != nil || !created {
		t.Fatalf("Submit() = (%t, %v)", created, err)
	}
	stored, found, err := requests.Latest(request.CaseID)
	if err != nil || !found || stored != request {
		t.Fatalf("Latest() = (%#v, %t, %v)", stored, found, err)
	}

	results, err := NewResultStore(filepath.Join(t.TempDir(), "results"))
	if err != nil {
		t.Fatal(err)
	}
	finalizer := &fakeFinalizer{outcome: queuefinalize.OutcomeFinalized}
	processor, err := NewProcessor(results, finalizer, func() time.Time { return createdAt.Add(time.Minute) })
	if err != nil {
		t.Fatal(err)
	}
	result, err := processor.Process(context.Background(), request)
	if err != nil || result.State != StateCompleted || result.Outcome != "finalized" ||
		finalizer.calls != 1 || finalizer.entry != request.Queue.Entry() {
		t.Fatalf("Process() = (%#v, %v), finalizer = %#v", result, err, finalizer)
	}
	result, err = processor.Process(context.Background(), request)
	if err != nil || result.State != StateCompleted || finalizer.calls != 1 {
		t.Fatalf("second Process() = (%#v, %v), calls = %d", result, err, finalizer.calls)
	}
}

func TestProcessorReportsChangedIdentityWithoutRemoval(t *testing.T) {
	t.Parallel()
	request, err := NewRequest(
		ServiceLidarr,
		"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		QueueIdentity{
			QueueID: 8, DownloadID: "download", SubjectID: 3,
			Status: "completed", TrackedDownloadStatus: "warning",
		},
		time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC),
	)
	if err != nil {
		t.Fatal(err)
	}
	results, err := NewResultStore(filepath.Join(t.TempDir(), "results"))
	if err != nil {
		t.Fatal(err)
	}
	finalizer := &fakeFinalizer{outcome: queuefinalize.OutcomeIdentityChanged}
	processor, err := NewProcessor(results, finalizer, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	result, err := processor.Process(context.Background(), request)
	if err != nil || result.State != StateFailed || result.Failure != "queue_identity_changed" {
		t.Fatalf("Process() = (%#v, %v)", result, err)
	}
}

func TestProcessorRecordsRetryableRemovalFailure(t *testing.T) {
	t.Parallel()
	request, err := NewRequest(
		ServiceRadarr,
		"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
		QueueIdentity{
			QueueID: 9, DownloadID: "download", SubjectID: 4,
			Status: "completed", TrackedDownloadStatus: "warning",
		},
		time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC),
	)
	if err != nil {
		t.Fatal(err)
	}
	results, err := NewResultStore(filepath.Join(t.TempDir(), "results"))
	if err != nil {
		t.Fatal(err)
	}
	finalizer := &fakeFinalizer{err: errors.New("unavailable")}
	processor, err := NewProcessor(results, finalizer, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	result, err := processor.Process(context.Background(), request)
	if err == nil || result.State != StateFailed || result.Failure != "remove_failed" {
		t.Fatalf("Process() = (%#v, %v)", result, err)
	}
	stored, found, readErr := results.Get(request)
	if readErr != nil || !found || stored != result {
		t.Fatalf("Get() = (%#v, %t, %v)", stored, found, readErr)
	}
}

type fakeFinalizer struct {
	outcome queuefinalize.Outcome
	err     error
	calls   int
	entry   queuefinalize.Entry
}

func (finalizer *fakeFinalizer) Finalize(
	_ context.Context,
	entry queuefinalize.Entry,
) (queuefinalize.Outcome, error) {
	finalizer.calls++
	finalizer.entry = entry
	return finalizer.outcome, finalizer.err
}

package dvdrequest

import (
	"context"
	"errors"
	"testing"

	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/dvdstage"
	"github.com/booxter/nix-config/media-repair/worker/failurelog"
)

type failingStager struct{ err error }

func (stager failingStager) StageOrRecover(
	context.Context, dvdstage.Specification,
) (dvdstage.Result, error) {
	return dvdstage.Result{}, stager.err
}

type recordingReporter struct{ events []failurelog.Event }

func (reporter *recordingReporter) Report(event failurelog.Event) {
	reporter.events = append(reporter.events, event)
}

func TestExecutorReportsCorrelatedWorkerFailure(t *testing.T) {
	t.Parallel()
	request := workercontracts.DVDRemuxRequestV1{
		RequestID: "request:test", CaseID: "case:test", ExecutionID: "execution:test",
	}
	cause := errors.New("staging failed")
	reporter := &recordingReporter{}
	executor, err := NewExecutor(failingStager{err: cause}, reporter)
	if err != nil {
		t.Fatal(err)
	}
	response := executor.Execute(context.Background(), request)
	if response.Failure == nil || response.Failure.Reason != "internal_error" {
		t.Fatalf("remux failure = %#v", response)
	}
	if len(reporter.events) != 1 {
		t.Fatalf("reported failures = %#v", reporter.events)
	}
	event := reporter.events[0]
	if event.Operation != "stage_dvd_remux_v1" || event.RequestID != request.RequestID ||
		event.CaseID != request.CaseID || event.ExecutionID != request.ExecutionID ||
		event.Reason != "internal_error" || event.Cause != cause {
		t.Fatalf("reported failure = %#v", event)
	}
}

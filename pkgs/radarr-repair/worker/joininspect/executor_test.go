package joininspect

import (
	"context"
	"errors"
	"testing"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/joinstate"
)

func TestInspectReportsStoredState(t *testing.T) {
	t.Parallel()

	tests := []struct {
		stored joinstate.State
		want   workercontracts.InspectJoinState
	}{
		{stored: joinstate.Prepared, want: workercontracts.InspectJoinPrepared},
		{stored: joinstate.Staged, want: workercontracts.InspectJoinStaged},
		{stored: joinstate.Published, want: workercontracts.InspectJoinPublished},
		{stored: joinstate.Discarded, want: workercontracts.InspectJoinDiscarded},
		{stored: joinstate.Failed, want: workercontracts.InspectJoinFailed},
	}
	for _, test := range tests {
		t.Run(string(test.stored), func(t *testing.T) {
			t.Parallel()
			executor := testExecutor(t, &fakeStore{
				execution: joinstate.Execution{State: test.stored},
				found:     true,
			})
			response := executor.Inspect(context.Background(), inspectRequest())
			if response.Kind != workercontracts.ProbeResponseSucceeded ||
				response.Success == nil || response.Failure != nil ||
				response.Success.State != test.want ||
				response.RequestID() != "request:inspect:01" {
				t.Fatalf("response = %#v", response)
			}
		})
	}
}

func TestInspectReportsAbsentExecution(t *testing.T) {
	t.Parallel()

	executor := testExecutor(t, &fakeStore{})
	response := executor.Inspect(context.Background(), inspectRequest())
	if response.Success == nil ||
		response.Success.State != workercontracts.InspectJoinAbsent {
		t.Fatalf("response = %#v", response)
	}
}

func TestInspectReportsInternalFailure(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		ctx     func() context.Context
		store   *fakeStore
		wantGet int
	}{
		{
			name: "store error",
			ctx:  context.Background,
			store: &fakeStore{
				err: errors.New("state unavailable"),
			},
			wantGet: 1,
		},
		{
			name: "invalid stored state",
			ctx:  context.Background,
			store: &fakeStore{
				execution: joinstate.Execution{State: "unknown"},
				found:     true,
			},
			wantGet: 1,
		},
		{
			name: "canceled request",
			ctx: func() context.Context {
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				return ctx
			},
			store: &fakeStore{},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			executor := testExecutor(t, test.store)
			response := executor.Inspect(test.ctx(), inspectRequest())
			if response.Failure == nil || response.Success != nil ||
				response.Failure.Reason != workercontracts.InspectJoinInternal ||
				test.store.calls != test.wantGet {
				t.Fatalf("response = %#v, store calls = %d", response, test.store.calls)
			}
		})
	}
}

func TestNewExecutorRequiresStore(t *testing.T) {
	t.Parallel()

	if _, err := NewExecutor(nil); err == nil {
		t.Fatal("missing store was accepted")
	}
}

type fakeStore struct {
	execution joinstate.Execution
	found     bool
	err       error
	calls     int
}

func (store *fakeStore) Get(string) (joinstate.Execution, bool, error) {
	store.calls++
	return store.execution, store.found, store.err
}

func testExecutor(t *testing.T, store Store) *Executor {
	t.Helper()
	executor, err := NewExecutor(store)
	if err != nil {
		t.Fatal(err)
	}
	return executor
}

func inspectRequest() workercontracts.InspectJoinRequestV1 {
	return workercontracts.InspectJoinRequestV1{
		ExecutionID:   "execution:join:01",
		Operation:     workercontracts.InspectJoinV1,
		RequestID:     "request:inspect:01",
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
	}
}

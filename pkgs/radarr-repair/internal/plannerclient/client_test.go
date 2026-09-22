package plannerclient

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
)

func TestClientPlansThroughUnixSocket(t *testing.T) {
	t.Parallel()

	repairCase := fixtureCase(t)
	wantDecision := fixtureDecision(t, repairCase.CaseID)
	decisionData := fixtureDecisionData(t, repairCase.CaseID)
	requests := make(chan contracts.RepairCaseV3, 1)
	socketPath := serveUnix(t, http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		plannedCase, err := readRepairCase(request)
		if err != nil {
			http.Error(writer, "invalid request", http.StatusBadRequest)
			return
		}
		requests <- plannedCase
		writer.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = writer.Write(decisionData)
	}))
	client := testClient(t, socketPath, time.Second)

	decision, err := client.Plan(context.Background(), repairCase)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(decision, wantDecision) {
		t.Fatalf("decision = %#v, want %#v", decision, wantDecision)
	}
	if plannedCase := <-requests; !reflect.DeepEqual(plannedCase, repairCase) {
		t.Fatalf("request = %#v, want %#v", plannedCase, repairCase)
	}
}

func TestClientRejectsInvalidResponses(t *testing.T) {
	t.Parallel()

	repairCase := fixtureCase(t)
	validDecision := fixtureDecisionData(t, repairCase.CaseID)
	wrongCaseID := "sha256:" + strings.Repeat("a", 64)
	mismatchedDecision := fixtureDecisionData(t, wrongCaseID)
	tests := []struct {
		name    string
		handler http.HandlerFunc
		kind    FailureKind
		status  int
	}{
		{
			name: "HTTP status",
			handler: func(writer http.ResponseWriter, _ *http.Request) {
				http.Error(writer, "do-not-expose-response", http.StatusServiceUnavailable)
			},
			kind:   FailureHTTP,
			status: http.StatusServiceUnavailable,
		},
		{
			name: "wrong content type",
			handler: func(writer http.ResponseWriter, _ *http.Request) {
				writer.Header().Set("Content-Type", "text/plain")
				_, _ = writer.Write(validDecision)
			},
			kind: FailureInvalidResponse,
		},
		{
			name: "malformed decision",
			handler: func(writer http.ResponseWriter, _ *http.Request) {
				writeJSON(writer, []byte("{"))
			},
			kind: FailureInvalidResponse,
		},
		{
			name: "oversized decision",
			handler: func(writer http.ResponseWriter, _ *http.Request) {
				writeJSON(writer, bytes.Repeat([]byte("x"), maxDecisionResponseSize+1))
			},
			kind: FailureInvalidResponse,
		},
		{
			name: "mismatched case ID",
			handler: func(writer http.ResponseWriter, _ *http.Request) {
				writeJSON(writer, mismatchedDecision)
			},
			kind: FailureInvalidResponse,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			socketPath := serveUnix(t, test.handler)
			client := testClient(t, socketPath, time.Second)
			_, err := client.Plan(context.Background(), repairCase)
			assertFailure(t, err, test.kind, test.status)
			if strings.Contains(fmt.Sprint(err), "do-not-expose-response") {
				t.Fatalf("error exposes response body: %v", err)
			}
		})
	}
}

func TestClientClassifiesUnavailablePlannerAndTimeout(t *testing.T) {
	t.Parallel()

	repairCase := fixtureCase(t)
	t.Run("unavailable", func(t *testing.T) {
		t.Parallel()
		socketPath := filepath.Join(t.TempDir(), "missing.sock")
		client := testClient(t, socketPath, time.Second)
		_, err := client.Plan(context.Background(), repairCase)
		assertFailure(t, err, FailureUnavailable, 0)
		if strings.Contains(err.Error(), socketPath) {
			t.Fatalf("error exposes socket path: %v", err)
		}
	})

	t.Run("permission denied", func(t *testing.T) {
		t.Parallel()
		if runtime.GOOS != "linux" {
			t.Skip("Unix socket permissions are enforced by Linux")
		}
		decisionData := fixtureDecisionData(t, repairCase.CaseID)
		socketPath := serveUnix(t, http.HandlerFunc(func(
			writer http.ResponseWriter,
			_ *http.Request,
		) {
			writeJSON(writer, decisionData)
		}))
		if err := os.Chmod(socketPath, 0); err != nil {
			t.Fatal(err)
		}
		client := testClient(t, socketPath, time.Second)
		_, err := client.Plan(context.Background(), repairCase)
		assertFailure(t, err, FailureUnavailable, 0)
		if strings.Contains(err.Error(), socketPath) {
			t.Fatalf("error exposes socket path: %v", err)
		}
	})

	t.Run("timeout", func(t *testing.T) {
		t.Parallel()
		socketPath := serveUnix(t, http.HandlerFunc(func(
			_ http.ResponseWriter,
			request *http.Request,
		) {
			<-request.Context().Done()
		}))
		client := testClient(t, socketPath, 20*time.Millisecond)
		_, err := client.Plan(context.Background(), repairCase)
		assertFailure(t, err, FailureTimeout, 0)
	})
}

func TestClientHonorsCallerCancellation(t *testing.T) {
	t.Parallel()

	client := testClient(
		t,
		filepath.Join(t.TempDir(), "missing.sock"),
		time.Second,
	)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := client.Plan(ctx, fixtureCase(t))
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v", err)
	}
}

func TestClientRejectsInvalidCase(t *testing.T) {
	t.Parallel()

	repairCase := fixtureCase(t)
	repairCase.CaseID = "sha256:" + strings.Repeat("f", 64)
	client := testClient(t, "/run/planner.sock", time.Second)
	if _, err := client.Plan(context.Background(), repairCase); err == nil {
		t.Fatal("invalid repair case was accepted")
	}
}

func TestNewRejectsInvalidConfiguration(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		socketPath string
		timeout    time.Duration
	}{
		{name: "empty socket", timeout: time.Second},
		{name: "relative socket", socketPath: "planner.sock", timeout: time.Second},
		{name: "unclean socket", socketPath: "/run/../planner.sock", timeout: time.Second},
		{name: "zero timeout", socketPath: "/run/planner.sock"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if _, err := New(test.socketPath, test.timeout); err == nil {
				t.Fatal("invalid configuration was accepted")
			}
		})
	}
}

func testClient(t *testing.T, socketPath string, timeout time.Duration) *Client {
	t.Helper()
	client, err := New(socketPath, timeout)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
	return client
}

func serveUnix(t *testing.T, handler http.Handler) string {
	t.Helper()
	socketPath := filepath.Join(t.TempDir(), "planner.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: handler}
	done := make(chan error, 1)
	go func() {
		done <- server.Serve(listener)
	}()
	t.Cleanup(func() {
		if err := server.Close(); err != nil {
			t.Errorf("close server: %v", err)
		}
		if err := <-done; err != nil && !errors.Is(err, http.ErrServerClosed) {
			t.Errorf("serve planner test requests: %v", err)
		}
	})
	return socketPath
}

func readRepairCase(request *http.Request) (contracts.RepairCaseV3, error) {
	if request.Method != http.MethodPost || request.URL.Path != "/v3/repair-plans" ||
		request.Header.Get("Content-Type") != "application/json" {
		return contracts.RepairCaseV3{}, fmt.Errorf("unexpected request")
	}
	data, err := io.ReadAll(request.Body)
	if err != nil {
		return contracts.RepairCaseV3{}, err
	}
	return contracts.DecodeCase(data)
}

func writeJSON(writer http.ResponseWriter, data []byte) {
	writer.Header().Set("Content-Type", "application/json")
	_, _ = writer.Write(data)
}

func fixtureCase(t *testing.T) contracts.RepairCaseV3 {
	t.Helper()
	repairCase, err := contracts.DecodeCase(readFixture(t, "repair-case-joinable.json"))
	if err != nil {
		t.Fatal(err)
	}
	repairCase.CaseID, err = contracts.CalculateCaseID(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	return repairCase
}

func fixtureDecision(t *testing.T, caseID string) contracts.RepairDecisionV3 {
	t.Helper()
	decision, err := contracts.DecodeDecision(fixtureDecisionData(t, caseID))
	if err != nil {
		t.Fatal(err)
	}
	return decision
}

func fixtureDecisionData(t *testing.T, caseID string) []byte {
	t.Helper()
	data := readFixture(t, "repair-decision-join.json")
	decision, err := contracts.DecodeDecision(data)
	if err != nil {
		t.Fatal(err)
	}
	return bytes.Replace(data, []byte(decision.CaseID()), []byte(caseID), 1)
}

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "contracts", "v3", "examples", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func assertFailure(t *testing.T, err error, wantKind FailureKind, wantStatus int) {
	t.Helper()
	var failure *Failure
	if !errors.As(err, &failure) || failure.Kind != wantKind ||
		failure.StatusCode != wantStatus {
		t.Fatalf("error = %#v, want kind %d and status %d", err, wantKind, wantStatus)
	}
}

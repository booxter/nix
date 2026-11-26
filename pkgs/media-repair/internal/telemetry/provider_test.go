package telemetry

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	collector "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type traceCollector struct {
	collector.UnimplementedTraceServiceServer
	requests chan *collector.ExportTraceServiceRequest
}

func (receiver *traceCollector) Export(_ context.Context, request *collector.ExportTraceServiceRequest) (*collector.ExportTraceServiceResponse, error) {
	receiver.requests <- request
	return &collector.ExportTraceServiceResponse{}, nil
}

func startCollector(t *testing.T, path string, receiver *traceCollector) *grpc.Server {
	t.Helper()
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	collector.RegisterTraceServiceServer(server, receiver)
	go server.Serve(listener)
	t.Cleanup(server.Stop)
	return server
}

func TestUnixExporterReconnectsAfterCollectorRestart(t *testing.T) {
	// Unix socket paths are limited to roughly 100 bytes, including TMPDIR.
	directory, err := os.MkdirTemp("/tmp", "repairr-otel-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	socket := filepath.Join(directory, "otlp.sock")
	receiver := &traceCollector{requests: make(chan *collector.ExportTraceServiceRequest, 4)}
	server := startCollector(t, socket, receiver)
	provider, err := NewProvider(context.Background(), "repairr-test", "unix://"+socket)
	if err != nil {
		t.Fatal(err)
	}
	defer provider.Shutdown(context.Background())

	for _, name := range []string{"before restart", "after restart"} {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		for {
			_, span := provider.Tracer("test").Start(ctx, name)
			span.End()
			err = provider.ForceFlush(ctx)
			if name == "before restart" || status.Code(err) != codes.Unavailable {
				break
			}
			// The exporter drops a failed batch. Send a fresh span while
			// gRPC reconnects to the replacement collector.
			select {
			case <-ctx.Done():
				t.Fatalf("collector did not reconnect: %v", err)
			case <-time.After(50 * time.Millisecond):
			}
		}
		cancel()
		if err != nil {
			t.Fatalf("export %q: %v", name, err)
		}
		select {
		case request := <-receiver.requests:
			resources := request.GetResourceSpans()
			if len(resources) != 1 {
				t.Fatalf("resource batches: got %d, want 1", len(resources))
			}
			spans := resources[0].ScopeSpans[0].Spans
			if len(spans) != 1 || spans[0].Name != name {
				t.Fatalf("exported spans: %v", spans)
			}
		default:
			t.Fatalf("collector did not receive %q", name)
		}
		if name == "before restart" {
			server.Stop()
			startCollector(t, socket, receiver)
		}
	}
}
